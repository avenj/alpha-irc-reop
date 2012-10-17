package Alpha::IRC::Reop;
our $VERSION = '0.01';

use 5.10.1;
use Carp;

use Moo;
use strictures 1;

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

use namespace::clean -except => 'meta';


## Attribs (public)

has 'casemap' => (
  lazy      => 1,
  is        => 'ro',
  writer    => 'set_casemap',
  predicate => 1,
  default   => sub { 'rfc1459' },
);

has 'config' => (
  required => 1,
  is       => 'ro',
  isa      => sub {
    blessed $_[0] and $_[0]->isa('Alpha::IRC::Reop::Config')
    or confess "$_[0] is not an Alpha::IRC::Reop::Config"
  },
);

has 'debug' => (
  is      => 'rw',
  default => sub { 0 },
  trigger => sub {
    my ($self, $val) = @_;
    require POSIX if $val;
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

has '_msg_queue' => (
  is      => 'ro',
  writer  => '_set_msg_queue',
  default => sub {  []  },
);


has '_limiter' => (
  lazy      => 1,
  is        => 'ro',
  writer    => '_set_limiter',
  predicate => '_has_limiter',
  default   => sub {
    my ($self) = @_;
    require Alpha::IRC::Reop::FloodLimit;
    Alpha::IRC::Reop::FloodLimit->new(
      limit => $self->config->limiter_count,
      secs  => $self->config->limiter_secs,
    )
  },
);


## Create a Session when this object is constructed:
sub BUILD {
  my ($self) = @_;

  $self->_limiter->expire
    if $self->config->has_limiter_count
    or $self->config->has_limiter_secs;

  ## Create a POE::Session and assign some states we can enter.
  POE::Session->create(
    object_states => [
      $self => [ qw/
        _start

        ac_check_lastseen
        ac_push_queue

        irc_001
        irc_chan_mode
        irc_chan_sync
        irc_kick
        irc_nick
        irc_part
        irc_public
        irc_quit
      / ],
      $self => {
        irc_ctcp_action => 'irc_public',
      },
    ],
  );
}

## Utility methods.
sub dbwarn {
  my $ti = POSIX::strftime( "%H:%M:%S", localtime );
  my $ca = (split /::/, ((caller 1)[3] || '') )[-1];
  warn map {; "$ti $ca $_\n" } @_
}

# Queue-related methods

sub __send_line {
  my ($self, $channel, $nick, $line) = @_;

  dbwarn " - sendline: $channel $nick $line" if $self->debug;

  $self->pocoirc->yield( sl_high =>
    sprintf( $line, $channel, $nick )
  )
}

sub __add_to_msg_queue {
  my ($self, $channel, $nick, @lines) = @_;

  my %base = (
    chan => lc_irc($channel, $self->casemap),
    nick => lc_irc($nick, $self->casemap),
  );

  for my $line (@lines) {
    my $ref = { %base, line => $line };
    push @{ $self->_msg_queue }, $ref;
    dbwarn " - queue add: $channel ($nick) $line" if $self->debug;
  }
}

sub __del_from_msg_queue {
  my ($self, $channel, $nick) = @_;

  dbwarn " - queue del: $channel ".($nick||'')
    if $self->debug;

  my @valid;

  QITEM: while (my $ref = shift @{ $self->_msg_queue }) {
    if (defined $nick) {
      next QITEM
        if  eq_irc( $ref->{nick}, $nick, $self->casemap )
        and eq_irc( $ref->{chan}, $channel, $self->casemap )
    } else {
      next QITEM
        if eq_irc( $ref->{chan}, $channel, $self->casemap )
    }

    push @valid, $ref
  }

  if ($self->debug) {
    my $delta = @{ $self->_msg_queue } - @valid;
    dbwarn "deleted $delta queued items";
  }

  $self->_set_msg_queue( [ @valid ] )
}

sub __clear_all {
  my ($self, $channel, $nick) = @_;

  ## Used by irc_part/irc_quit.

  ($channel, $nick) = map {; lc_irc($_, $self->casemap) } ($channel, $nick);

  $self->__del_from_msg_queue( $channel, $nick );

  for my $type (qw/ _current_ops _pending_ops /) {
    dbwarn "clearing $type $channel $nick" if $self->debug;
    delete $self->$type->{$channel}->{$nick}
      if exists $self->$type->{$channel}->{$nick}
  }
}

sub __try_reop {
  my ($self, $channel) = @_;

  ## Try to regain ops via configured means.

  return unless $self->config->has_reop_sequence;

  dbwarn "trying to regain ops on $channel" if $self->debug;

  for my $line (@{ $self->config->reop_sequence }) {
    $self->pocoirc->yield( sl_high =>
      sprintf($line, $channel, $self->pocoirc->nick_name)
    );
  }
}


# Batched mode change utils / convenience methods

sub __issue_modes {
  ## ->__issue_modes($channel, '+', 'v', @nicks)  # f.ex
  my ($self, $channel, $type, $mode, @nicknames) = @_;

  confess "Expected channel, + or - flag, mode, and list of targets"
    unless @nicknames;

  my $max = $self->pocoirc->isupport('MODES') || 3;

  my @targets;

  while (my $nick = shift @nicknames) {
    push(@targets, $nick);
    if (!@nicknames || @targets == $max) {
      $self->pocoirc->yield( mode => $channel,
        $type . ( $mode x @targets),
        @targets
      );
      @targets = ();
    }
  }
}

sub __issue_voice {
  my ($self, $channel, @nicknames) = @_;
  $self->__issue_modes( $channel, '+', 'v', @nicknames )
}

sub __remove_voice {
  my ($self, $channel, @nicknames) = @_;
  $self->__issue_modes( $channel, '-', 'v', @nicknames )
}

sub __issue_op {
  my ($self, $channel, @nicknames) = @_;
  $self->__issue_modes( $channel, '+', 'o', @nicknames )
}

sub __remove_op {
  my ($self, $channel, @nicknames) = @_;
  $self->__issue_modes( $channel, '-', 'o', @nicknames )
}

## POE states.
sub _start {
  ## _start is called by the POE::Kernel when this Session becomes active
  ## (which is Session creation time in a running Kernel, or when the
  ## Kernel is ->run() otherwise)
  my ($kernel, $self) = @_[KERNEL, OBJECT];

  if ($self->debug) {
    warn "-> current config:\n", $self->config->dumped;
  }

  my $irc = POE::Component::IRC::State->spawn(
    flood    => 1,
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

  $irc->plugin_add( 'Connector' =>
    POE::Component::IRC::Plugin::Connector->new(
      delay     => 120,
      reconnect => 20,
    ),
  );

  $irc->yield(register => 'all');

  $irc->yield(connect => +{});
}


## irc_* states

sub irc_001 {
  my ($kernel, $self) = @_[KERNEL, OBJECT];

  my $casemap = $self->pocoirc->isupport('CASEMAP') || 'rfc1459';

  dbwarn "connected, setting CASEMAP $casemap" if $self->debug;

  $self->set_casemap( $casemap );
  $self->config->normalize_channels( $casemap );

  if ( $self->config->has_umode ) {
    my $mode = $self->config->umode || '+i';
    my $me   = $self->pocoirc->nick_name;
    $self->pocoirc->yield( 'mode', $me, $mode );
  }
}

sub irc_public {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my ($src, $where)   = @_[ARG0, ARG1];

  my $nick = lc_irc( parse_user($src), $self->casemap );

  ## If this is a known op update 'lastseen'
  ## If this is a pending op, reop, move to known ops

  my $own_nick = $self->pocoirc->nick_name;

  TARGET: for my $channel (map {; lc_irc($_, $self->casemap) } @$where) {
    ## ctcp_action is mapped here; ignore private actions:
    next TARGET unless $channel =~ /^[+&#]/;

    if (exists $self->_current_ops->{$channel}->{$nick}) {
      $self->_current_ops->{$channel}->{$nick} = time();
      dbwarn "updated _current_ops $channel $nick" if $self->debug;
      next TARGET
    }

    if (exists $self->_pending_ops->{$channel}->{$nick}) {
      dbwarn "handling pending op $channel $nick" if $self->debug;

      ## Clear any pending sequences in msg queue.
      $self->__del_from_msg_queue( $channel, $nick );

      delete $self->_pending_ops->{$channel}->{$nick};

      unless ($self->pocoirc->is_channel_operator($channel, $own_nick)) {
        $self->__try_reop($channel);
      }

      if ( $self->config->has_up_sequence ) {
        dbwarn "issuing up_sequence" if $self->debug;

        for my $line (@{ $self->config->up_sequence }) {
          ## FIXME should we have a higher-priority queue for these?
          ##  (Re-opping takes precendece over deopping)
          ##  ... or just say fuckit and send it?
          $self->__send_line( $channel, $nick, $line );
        }
      } else {
        dbwarn "mode bounce -v+o $channel $nick" if $self->debug;

        $self->pocoirc->yield( mode => $channel,
          '-v+o', ($nick) x 2
        );
      }

      dbwarn "updating _current_ops for $channel $nick (irc_public)"
        if $self->debug;

      $self->_current_ops->{$channel}->{$nick} = time();

      next TARGET
    }

  } # TARGET
}

sub irc_chan_sync {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my $chan = lc_irc( $_[ARG0], $self->casemap );

  ## Just in case these lists have been fucked with, clear 'em:
  $self->__del_from_msg_queue( $chan );
  for my $type (qw/ _current_ops _pending_ops /) {
    $self->$type->{$chan} = {}
  }

  ## Grab current users-with-status
  for my $nick ( $self->pocoirc->channel_list($chan) ) {
    next unless $self->pocoirc->is_channel_operator($chan, $nick);

    dbwarn "setting up initial _current_ops $chan $nick"
      if $self->debug;

    $nick = lc_irc( $nick, $self->casemap );
    $self->_current_ops->{$chan}->{$nick} = time();
  }

  my $own_nick = $self->pocoirc->nick_name;
  $self->__try_reop($chan)
    unless $self->pocoirc->is_channel_operator( $chan, $own_nick );

  ## Start checking for idle ops in 20 seconds.
  $kernel->delay_set( 'ac_check_lastseen', 20, $chan );

  dbwarn "timer init for $chan"
    if $self->debug;
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

  dbwarn "handling mode change $channel ${type}${modechr} $nick"
    if $self->debug;

  for ($type) {
    when ('+') {
      ## User gained +o ; add to _current_ops
      dbwarn "_current_ops added $channel $nick"
        if $self->debug;

      $self->_current_ops->{$channel}->{$nick} = time();

      dbwarn "clearing any remaining _pending_ops $channel $nick"
        if $self->debug;

      delete $self->_pending_ops->{$channel}->{$nick}
        if exists $self->_pending_ops->{$channel}->{$nick}
    }
    when ('-') {
      $self->__try_reop($channel)
        if eq_irc( $nick, $self->pocoirc->nick_name, $self->casemap );
      ## Remove from _current_ops
      ## Doesn't add to pending_ops:
      ##  - If we changed this mode, we tweaked pending_ops
      ##  - If someone else did, trust the change and stop watching
      dbwarn "_current_ops dropped $channel $nick"
        if $self->debug;

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
  ($old, $new) = map {; lc_irc($_, $self->casemap) } ($old, $new);

  TYPE: for my $type (qw/ _current_ops _pending_ops /) {
    CHAN: for my $channel (map {; lc_irc($_, $self->casemap) } @$common) {
      next CHAN unless exists $self->$type->{$channel}->{$old};

      dbwarn "nick adjusted $type $channel $old -> $new"
        if $self->debug;

      $self->$type->{$channel}->{$new} =
        delete $self->$type->{$channel}->{$old}
    } # CHAN
  } # TYPE
}

sub irc_kick {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my ($src, $channel) = @_[ARG0, ARG1];
  my ($nick) = parse_user($src);

  ## Same deal as irc_part

  if ( eq_irc($nick, $self->pocoirc->nick_name, $self->casemap) ) {
    dbwarn "clearing metadata for $channel due to KICK"
      if $self->debug;

    $self->__del_from_msg_queue($channel);

    for my $type (qw/ _current_ops _pending_ops /) {
      delete $self->$type->{ lc_irc($channel, $self->casemap) }
    }

    return
  }

  $self->__clear_all( $channel, $nick );
}

sub irc_part {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  my ($src, $channel) = @_[ARG0, ARG1];

  my $nick = lc_irc( parse_user($src), $self->casemap );
  ## Lost a user, update either hash accordingly.

  if ( eq_irc($nick, $self->pocoirc->nick_name, $self->casemap) ) {
    ## If this was us, delete the channel.
    $channel = lc_irc($channel, $self->casemap);
    dbwarn "clearing channel $channel due to PART" if $self->debug;

    $self->__del_from_msg_queue($channel);

    for my $type (qw/ _current_ops _pending_ops/) {
      delete $self->$type->{$channel}
    }
    return
  }

  dbwarn "PART seen ($channel $nick), calling __clear_all"
    if $self->debug;
  $self->__clear_all( $channel, $nick );
}

sub irc_quit {
  my ($kernel, $self)      = @_[KERNEL, OBJECT];
  my ($src, $msg, $common) = @_[ARG0 .. ARG2];

  my $nick = lc_irc( parse_user($src), $self->casemap );

  ## Same deal as PART, except we have to check channels we knew
  ## we had in common.

  for my $channel (map {; lc_irc($_, $self->casemap) } @$common) {
    dbwarn "clearing all for $channel $nick due to QUIT" if $self->debug;

    $self->__clear_all( $channel, $nick );
  }
}


## ac_* states

sub ac_push_queue {
  my ($kernel, $self) = @_[KERNEL, OBJECT];

  return unless @{ $self->_msg_queue };

  dbwarn "ac_push_queue fired" if $self->debug;

  unless ( $self->_has_limiter ) {
    ## No limiter. Clear queue.
    dbwarn "do not have limiter; pushing queue" if $self->debug;
    while (my $ref = shift @{ $self->_msg_queue }) {
      $self->__send_line(
        $ref->{chan},
        $ref->{nick},
        $ref->{line}
      )
    }

    return
  }

  if (my $delayed = $self->_limiter->check('send') ) {
    ## Delayed.
    dbwarn "ac_push_queued (pre) delayed $delayed seconds" if $self->debug;
    $kernel->alarm( 'ac_push_queue', time() + $delayed );
    return
  }

  ## Not delayed, get next
  dbwarn "ac_push_queue pushing one line" if $self->debug;
  my $nextref = shift @{ $self->_msg_queue };

  my $remain = @{ $self->_msg_queue };
  dbwarn "ac_push_queue: $remain queued items remaining" if $self->debug;

  $self->__send_line(
    $nextref->{chan},
    $nextref->{nick},
    $nextref->{line}
  );

  if ($remain) {
    if (my $delayed = $self->_limiter->check('send') ) {
      ## Delayed now.
      dbwarn "ac_push_queued (post) delayed $delayed seconds"
        if $self->debug;
      $kernel->alarm( 'ac_push_queue', time() + $delayed );
      return
    }

    ## Not delayed. yield back.
    $kernel->alarm( 'ac_push_queue' );
    $kernel->yield( 'ac_push_queue' );
  } else {
    dbwarn "Queue has been emptied" if $self->debug;
  }
}

sub ac_check_lastseen {
  my ($kernel, $self) = @_[KERNEL, OBJECT];
  ## Check lastseen users to see if anyone should have modes
  ## removed (configurable delta)

  my $channel = $_[ARG0];

  dbwarn "timer fired ac_check_lastseen for $channel" if $self->debug;

  unless ( $self->pocoirc->channel_list($channel) ) {
    ## Lost this channel. May be a stale timer.
    dbwarn "no channel_list for $channel, resetting, dropping timer"
      if $self->debug;

    for my $type (qw/ _current_ops _pending_ops/) {
      delete $self->$type->{$channel}
    }

    return
  }

  my $own_nick = $self->pocoirc->nick_name;
  unless ( $self->pocoirc->is_channel_operator($channel, $own_nick) ) {
    $self->__try_reop($channel);
  }

  my @targets;

  ## Check our tracked current ops.
  for my $nick (keys %{ $self->_current_ops->{$channel} }) {
    if ( eq_irc($nick, $self->pocoirc->nick_name, $self->casemap) ) {
      ## This is us.
      next
    }

    if ( $self->config->has_excepted
      && grep {; eq_irc($_, $nick, $self->casemap) }
        @{ $self->config->excepted } ) {
      ## Excepted nickname.
      dbwarn " - skipping excepted nick $nick" if $self->debug;
      next
    }

    unless ( $self->pocoirc->is_channel_operator($channel, $nick) ) {
      ## User not an operator.
      dbwarn " - clearing _current_ops $channel $nick (not opped)"
        if $self->debug;
      delete $self->_current_ops->{$channel}->{$nick};
      next
    }

    my $last_ts   = $self->_current_ops->{$channel}->{$nick};
    my $ccfg      = $self->config->channels->{$channel};
    my $allowable = blessed $ccfg ? $ccfg->delta : 900 ;

    if (time - $last_ts >= $allowable) {
      ## Exceeded delta, drop modes and add to _pending_ops

      dbwarn " - delta exceeded for $channel $nick, issuing DOWN"
        if $self->debug;

      if ( $self->config->has_down_sequence ) {
        dbwarn "  - issuing down sequence for $channel $nick"
          if $self->debug;

        $self->__add_to_msg_queue(
          $channel,
          $nick,
          @{ $self->config->down_sequence }
        ) if @{ $self->config->down_sequence };

        $kernel->alarm( 'ac_push_queue' );
        $kernel->yield( 'ac_push_queue' );
      } else {
        push @targets, $nick
      }

      dbwarn "  - setting _pending_ops $channel $nick" if $self->debug;

      ## Kill _current_ops entry; we've issued a deop already.
      ## If it never takes effect, retrying indefinitely is stupid.
      delete $self->_current_ops->{$channel}->{$nick};
      $self->_pending_ops->{$channel}->{$nick} = 1;
    }
  }

  if (@targets) {
    dbwarn "  - issuing modes ($channel)" if $self->debug;
    ## No down sequence, issue batched modes.
    if (@targets == 1) {
      $self->pocoirc->yield( mode => $channel,
        '+v-o', ($targets[0]) x 2
      );
    } else {
      $self->__issue_voice($channel, @targets);
      $self->__remove_op($channel, @targets);
   }
  }

  ## Check for idle ops again in 15 seconds.
  dbwarn " - timer reset for $channel" if $self->debug;
  $kernel->delay_set( 'ac_check_lastseen', 15, $channel );
}

1;

=pod

=head1 NAME

Alpha::IRC::Reop - Automatically manage idle IRC chanops

=head1 SYNOPSIS

  use POE;
  use Alpha::IRC::Reop;
  use Alpha::IRC::Reop::Config;

  my $alpha = Alpha::IRC::Reop->new(
    debug  => 0,
    config => Alpha::IRC::Reop::Config->from_file( $cfg_path ),
  );

  $poe_kernel->run;

=head1 DESCRIPTION

Joins configured channels and begins monitoring opped users.

If a user does not speak for a configurable amount of time, a configured
'DownSequence' is executed, or mode C<-o+v> is set if a DownSequence is
not specified. When the user resumes activity on the channel, an
'UpSequence' is executed, or mode C<+o-v> is set.

External mode changes are trusted to be authoritative; if a user is opped
by external means, we begin monitoring them for activity. If a user is
deopped by external means, we trust the change and do not reop.

See L<Alpha::IRC::Reop::Config> for configuration-related details.

=head2 casemap

Retrieves the CASEMAP value currently in use; this is set from ISUPPORT
details given by the server (or defaults to RFC1459 rules).

=head2 config

Retrieves the L<Alpha::IRC::Reop::Config> object.

=head2 debug

  $alpha->debug( $bool );

Turn debugging on/off or retrieve current debug boolean.

=head2 pocoirc

Retrieves the current L<POE::Component::IRC> object.

=head1 AUTHOR

Jon Portnoy <avenj@cobaltirc.org> per specifications set forth by Joah
& AlphaChat staff <admin@alphachat.net>

=cut
