package Alpha::IRC::Reop;
our $VERSION = '0.01';

## FIXME
##  - Needs to handle public actions the same way as irc_public
##  - Batch mode changes? Requires pulling ISUPPORT MODES=

## Require recent perl:
use 5.10.1;
## More useful complaints/exceptions with caller details:
use Carp;

## Moo all the things \o/
use Moo;
use strictures 1;

## POE supports list-style module imports:
use POE qw/
  Component::IRC::State
  Component::IRC::Plugin::AutoJoin
  Component::IRC::Plugin::Connector
  Component::IRC::Plugin::NickReclaim
  Component::IRC::Plugin::NickServID
/;

use IRC::Utils qw/
  parse_user
  eq_irc uc_irc lc_irc
/;

use Scalar::Util 'blessed';

## Every sub imported before this 'use' is assumed to be
## not-a-method and cleaned:
use namespace::clean -except => 'meta';


## Attribs (public)

has 'casemap' => (
  lazy      => 1,
  is        => 'ro',
  writer    => 'set_casemap',
  predicate => 1,
);

has 'config' => (
  required => 1,
  is       => 'ro',
  isa      => sub {
    blessed $_[0] and $_[0]->isa('Alpha::IRC::Reop::Config')
    or confess "$_[0] is not an Alpha::IRC::Reop::Config"
  },
);

has 'pocoirc' => (
  lazy      => 1,
  is        => 'ro',
  writer    => 'set_pocoirc',
  predicate => 1,
  isa       => sub {
    blessed $_[0] and $_[0]->isa('POE::Component::IRC')
    or confess "$_[0] is not a POE::Component::IRC"
  },
);


## Attribs (private)

## These two hashes are keyed such that: ->{$channel}{$nick} = $value
has '_current_ops' => (
  ## Known ops and the last time we saw them speak
  lazy    => 1,
  is      => 'ro',
  writer  => '_set_current_ops',
  default => sub {  {}  },
);

has '_pending_ops' => (
  ## Idle ops.
  lazy    => 1,
  is      => 'ro',
  writer  => '_set_pending_ops',
  default => sub {  {}  },
);


## Create a Session when this object is constructed:
sub BUILD {
  my ($self) = @_;

  ## Create a POE::Session and assign some states we can enter.
  POE::Session->create(
    object_states => [
      $self => [ qw/
        _start

        ac_check_lastseen

        irc_001
        irc_chan_mode
        irc_chan_sync
        irc_kick
        irc_nick
        irc_part
        irc_public
        irc_quit
      / ],
    ],
  );
}

## Utility methods.
sub __clear_all {
  my ($self, $channel, $nick) = @_;

  ## Used by irc_part/irc_quit.

  ($channel, $nick) = map { lc_irc($_, $self->casemap) } ($channel, $nick);

  for my $type (qw/ _current_ops _pending_ops /) {
    delete $self->$type->{$channel}->{$nick}
      if exists $self->$type->{$channel}->{$nick}
  }
}

sub __try_reop {
  my ($self, $channel) = @_;

  ## Try to regain ops via configured means.

  return unless $self->config->has_reop_sequence;

  for my $line (@{ $self->config->reop_sequence }) {
    $self->pocoirc->yield( sl_high =>
      sprintf($line, $channel, $self->pocoirc->nick_name)
    );
  }
}


## POE states.
sub _start {
  ## _start is called by the POE::Kernel when this Session becomes active
  ## (which is Session creation time in a running Kernel, or when the
  ## Kernel is ->run() otherwise)
  my ($kernel, $self) = @_[KERNEL, OBJECT];

  my $irc = POE::Component::IRC::State->spawn(
    nick     => $self->config->nickname,
    username => $self->config->username,
    ircname  => $self->config->realname,
    server   => $self->config->server,
    port     => $self->config->port,
    usessl   => $self->config->ssl,
    useipv6  => $self->config->ipv6,
    (
      $self->config->has_bindaddr ? (localaddr => $self->config->bindaddr)
        : ()
    ),
    (
      $self->config->has_password ? (password => $self->config->password)
        : ()
    ),
  ) or die "PoCo::IRC fatal: $!";

  ## Preserve the IRC component's object.
  $self->set_pocoirc($irc);

  $irc->plugin_add( 'NickReclaim' =>
    POE::Component::IRC::Plugin::NickReclaim->new(
      poll => 20,
    ),
  );

  if ( $self->config->has_nickserv_pass ) {
    $irc->plugin_add( 'NickServID' =>
      POE::Component::IRC::Plugin::NickServID->new(
        Password => $self->config->nickserv_pass,
      ),
    );
  }

  my @channels = keys %{ $self->config->channels };
  my %ajoin_prefs;

  for my $channel (@channels) {
    my $key = $self->config->channels->{$channel}->key || '';
    $ajoin_prefs{$channel} = $key;
  }

  $irc->plugin_add( 'AutoJoin' =>
    POE::Component::IRC::Plugin::AutoJoin->new(
      Channels          => \%ajoin_prefs,
      RejoinOnKick      => 1,
      Rejoin_delay      => 2,
      NickServ_delay    => 1,
      Retry_when_banned => 20,
    ),
  );

  $irc->yield(register => 'all');

  $irc->yield(connect => {});
}


## irc_* states

sub irc_001 {
  my ($kernel, $self) = @_[KERNEL, OBJECT];

  my $casemap = $self->pocoirc->isupport('CASEMAP') || 'rfc1459';
  $self->set_casemap( $casemap );
  $self->config->normalize_channels( $casemap );
}

sub irc_public {
  my ($kernel, $self)     = @_[KERNEL, OBJECT];
  my ($src, $where, $txt) = @_[ARG0 .. ARG2];

  my $nick = lc_irc( parse_user($src), $self->casemap );

  ## If this is a known op update 'lastseen'
  ## If this is a pending op, reop, move to known ops

  my $own_nick = $self->pocoirc->nick_name;

  TARGET: for my $channel (map { lc_irc($_, $self->casemap) } @$where) {

    if (exists $self->_current_ops->{$channel}->{$nick}) {
      $self->_current_ops->{$channel}->{$nick} = time();
      next TARGET
    }

    if (exists $self->_pending_ops->{$channel}->{$nick}) {
      delete $self->_pending_ops->{$channel}->{$nick};

      unless ($self->pocoirc->is_channel_operator($channel, $own_nick)) {
        $self->__try_reop($channel)
      }

      if ( $self->config->has_up_sequence ) {
        for my $line (@{ $self->config->up_sequence }) {
          $self->pocoirc->yield( sl_high =>
            sprintf($line, $channel, $nick)
          );
        }
      } else {
        $self->pocoirc->yield( mode => $channel,
          '-v+o', ($nick) x 2
        );
      }

      $self->_current_ops->{$channel}->{$nick} = time();

      next TARGET
    }

  } # TARGET
}

sub irc_chan_sync {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my $chan = lc_irc( $_[ARG0], $self->casemap );

  ## Just in case these lists have been fucked with, clear 'em:
  for my $type (qw/ _current_ops _pending_ops/) {
    $self->$type->{$chan} = {}
  }

  ## Grab current users-with-status
  for my $nick ( $self->pocoirc->channel_list($chan) ) {
    $nick = lc_irc( $nick, $self->casemap );
    next unless $self->pocoirc->is_channel_operator($chan, $nick);
    $self->_current_ops->{$chan}->{$nick} = time();
  }

  ## Start checking for idle ops in 20 seconds.
  $kernel->delay_set( 'ac_check_lastseen', 20, $chan );
}

sub irc_kick {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my ($src, $channel) = @_[ARG0, ARG1];
  my ($nick) = parse_user($src);

  ## Same deal as irc_part

  if ( eq_irc($nick, $self->pocoirc->nick_name, $self->casemap) ) {
    for my $type (qw/ _current_ops _pending_ops /) {
      delete $self->$type->{ lc_irc($channel, $self->casemap) }
    }
    return
  }

  $self->__clear_all( $channel, $nick );
}

sub irc_chan_mode {
  my ($kernel, $self) = @_[KERNEL, OBJECT];

  ## Track added/removed status modes
  ## Add to _current_ops
  ## This event is from ::State and fires once per individual mode.

  my ($src, $channel, $modestr, $nick) = @_[ARG0 .. $#_];
  $channel = lc_irc($channel, $self->casemap);

  my ($type, $modechr) = split //, $modestr;

  ## Only care about op changes:
  return unless $modechr eq 'o';

  $nick = lc_irc($nick, $self->casemap);

  if ( eq_irc($nick, $self->pocoirc->nick_name, $self->casemap) ) {
    ## Mode changed by us; we don't care, we adjusted elsewhere.
    return
  }

  for ($type) {
    when ('+') {
      ## User gained +o ; add to _current_ops
      $self->_current_ops->{$channel}->{$nick} = time();
    }
    when ('-') {
      ## Someone else deopped this user.
      ## Remove from _current_ops
      delete $self->_current_ops->{$channel}->{$nick}
        if exists $self->_current_ops->{$channel}->{$nick}
    }
  }
}

sub irc_nick {
  my ($kernel, $self) = @_[KERNEL, OBJECT];

  my ($src, $new, $common) = @_[ARG0 .. ARG2];

  my ($old) = parse_user($src);

  ## Track nick changes, update either hash accordingly.
  ($old, $new) = map { lc_irc($_, $self->casemap) } ($old, $new);

  TYPE: for my $type (qw/ _current_ops _pending_ops /) {
    CHAN: for my $channel (map { lc_irc($_, $self->casemap) } @$common) {
      next CHAN unless exists $self->$type->{$channel}->{$old};

      $self->$type->{$channel}->{$new} =
        delete $self->$type->{$channel}->{$old}
    } # CHAN
  } # TYPE
}

sub irc_part {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my ($src, $channel) = @_[ARG0, ARG1];

  my $nick = lc_irc( parse_user($src), $self->casemap );
  ## Lost a user, update either hash accordingly.

  if ( eq_irc($nick, $self->pocoirc->nick_name, $self->casemap) ) {
    ## If this was us, delete the channel.
    for my $type (qw/ _current_ops _pending_ops/) {
      delete $self->$type->{ lc_irc($channel, $self->casemap) }
    }
    return
  }

  $self->__clear_all( $channel, $nick );
}

sub irc_quit {
  my ($kernel, $self)      = @_[KERNEL, OBJECT];
  my ($src, $msg, $common) = @_[ARG0 .. ARG2];

  my $nick = lc_irc( parse_user($src), $self->casemap );

  ## Same deal as PART, except we have to check channels we knew
  ## we had in common.

  for my $channel (map { lc_irc($_, $self->casemap) } @$common) {
    $self->__clear_all( $channel, $nick );
  }
}


## ac_* states

sub ac_check_lastseen {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  ## Check lastseen users to see if anyone should have modes
  ## removed (configurable delta)

  my $channel = $_[ARG0];

  unless ( $self->pocoirc->channel_list($channel) ) {
    ## Lost this channel. May be a stale timer.
    for my $type (qw/ _current_ops _pending_ops/) {
      delete $self->$type->{$channel}
    }

    return
  }

  my $own_nick = $self->pocoirc->nick_name;
  unless ( $self->pocoirc->is_channel_operator($channel, $own_nick) ) {
    $self->__try_reop($channel)
  }

  ## Check our tracked current ops.
  for my $nick (keys %{ $self->_current_ops->{$channel} }) {
    if ( eq_irc($nick, $self->pocoirc->nick_name, $self->casemap) ) {
      ## This is us.
      next
    }

    unless ( $self->pocoirc->is_channel_operator($channel, $nick) ) {
      ## User not an operator.
      delete $self->_current_ops->{$channel}->{$nick};
      next
    }

    my $last_ts = $self->_current_ops->{$channel}->{$nick};
    my $allowable = $self->config->channels->{$channel}->delta;

    if (time - $last_ts >= $allowable) {
      ## Exceeded delta, drop modes and add to _pending_ops

      if ( $self->config->has_down_sequence ) {

        for my $line (@{ $self->config->down_sequence }) {
          $self->pocoirc->yield( sl_high =>
            sprintf($line, $channel, $nick)
          );
        }

      } else {
        $self->pocoirc->yield( mode => $channel,
          '-o+v', ($nick) x 2
        );
      }

      $self->_pending_ops->{$channel}->{$nick} = 1;
    }
  }

  ## Check for idle ops again in five seconds.
  $kernel->delay_set( 'ac_check_lastseen', 5, $channel );
}


1;
