package Alpha::IRC::Reop;

use 5.10.1;
use Carp;

use Moo;
use strictures 1;

use POE qw/
  Component::IRC::State
  Component::IRC::Plugin::AutoJoin
  Component::IRC::Plugin::Connector
  Component::IRC::Plugin::NickReclaim
/;

use IRC::Utils qw/
  uc_irc lc_irc
/;

use Scalar::Util 'blessed';



has 'config' => (
  required => 1,
  is       => 'ro',
  isa      => sub {
    blessed $_[0] and $_[0]->isa('Alpha::IRC::Config')
    or confess "$_[0] is not an Alpha::IRC::Config"
  },
);


has 'current_ops' => (
  ## Known ops and the last time we saw them speak
  ## Add to this hash when opped (FIXME configurable?)
  ## Remove and move to 'tracking' with their status modes
  ## if they go idle
  lazy    => 1,
  is      => 'ro',
  writer  => 'set_current_ops',
  default => sub {  {}  },
);

has 'pending_ops' => (
  lazy    => 1,
  is      => 'ro',
  writer  => 'set_pending_ops',
  default => sub {  {}  },
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


## Create a Session when this object is instantiated.
sub BUILD {
  my ($self) = @_;

  POE::Session->create(
    heap => {
      lastseen => {},
      ## Users that may need to be reopped:
      tracking => {},
    },
    object_states => [
      $self => [ qw/
        _start

        ac_check_lastseen

        irc_public
        irc_chan_sync
        irc_nick
        irc_part
        irc_quit
      / ],
    ],
  );
}


## POE states.
sub _start {
  my ($kernel, $heap) = @_[KERNEL, HEAP];

  my $irc = POE::Component::IRC::State->spawn(
    ## FIXME
  ) or die "PoCo::IRC fatal: $!";

  $irc->plugin_add() ## FIXME Connector, AutoJoin, NickServID ?

  $self->set_pocoirc($irc);

  $irc->yield(register => 'all');

  $irc->yield(connect => {});
}


## irc_* states

sub irc_public {
  ## If this is a known op update 'lastseen'
}

sub irc_chan_sync {
  ## Grab current operators (configurable?)
  ## Set ac_check_lastseen timer
}

sub irc_mode {
  ## Track added/removed status modes
}

sub irc_nick {
  ## Track nick changes, update hashes accordingly
  ## (Needs to check against both, potentially)
}

sub irc_part {
  ## See if we care that we lost this user
}

sub irc_quit {
  ## Same deal as _part
}


## ac_* states

sub ac_check_lastseen {
  my ($self, $kernel) = @_;
  ## Check lastseen users to see if anyone should have modes
  ## removed (configurable delta)

  my $channel = $_[ARG0];

  for my $nick (keys %{ $self->current_ops }) {
    my $last_ts = $self->current_ops->{$nick};
    ## FIXME ->
    my $allowable = $self->config->channels->{$channel}->delta;
    if (time - $last_ts >= $allowable) {
      ## FIXME get all (configured..?) status modes for this user
      ##  (check State docs on this)
      ##  drop them and add the mode chars to pending_ops
    }
  }

  ## FIXME reset timer
}

1;

## FIXME per-channel configurable re-op cmd?
##  would allow for configurably using bots/services on certain chans
