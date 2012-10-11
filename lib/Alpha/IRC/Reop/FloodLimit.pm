package Alpha::IRC::Reop::FloodLimit;

use Carp;
use Moo;

use strictures 1;

has 'limit' => (
  is       => 'ro',
  required => 1,
);

has 'secs'  => (
  is       => 'ro',
  required => 1,
);

has '_fqueue' => (
  is      => 'rw',
  default => sub {  {}  },
);


sub check {
  my ($self, $key) = @_;
  return unless defined $key;

  my $this_ref = $self->_fqueue->{$key} //= [];

  if (@$this_ref >= $self->limit) {
    my $oldest  = $this_ref->[0];
    my $pending = @$this_ref;
    my $ev_c    = $self->limit;
    my $ev_sec  = $self->secs;

    my $delayed = int(
      ($oldest + ($pending * $ev_sec / $ev_c) ) - time()
    );

    return $delayed if $delayed > 0;

    shift @$this_ref
  }

  push @$this_ref, time();
  return 0
}

sub clear {
  my ($self, $key) = @_;
  confess "clear() called with no key" unless defined $key;
  delete $self->_fqueue->{$key}
}

sub expire {
  my ($self) = @_;
  KEY: for my $key (keys %{ $self->_fqueue } ) {
    my @events = @{ $self->_fqueue->{$key} };
    my $latest = $events[-1] // next KEY;
    if ( time() - $latest > $self->secs ) {
      $self->clear($key)
    }
  }
}

1;

=pod

=head1 NAME

Alpha::IRC::Reop::FloodLimit

=head1 SYNOPSIS

  ## 4 in 5 secs rate-limiter
  my $fcheck = Alpha::IRC::Reop::FloodLimit->new(
    limit => 4,
    secs  => 5,
  );

  if (my $delay = $fcheck->check($this_user) ) {
    ## Delayed $delay secs
  } else {
    ## Not delayed
  }

  ## Clear a user's seen events
  $fcheck->clear($this_user);

  ## Check for stale events
  $fcheck->expire;

=head1 DESCRIPTION

Generic rate-limiter.

=head1 AUTHOR

Jon Portnoy <avenj@cobaltirc.org>, based on L<Bot::Cobalt::IRC::FloodChk>, 
which is in turn derived from L<Algorithm::FloodControl>

=cut
