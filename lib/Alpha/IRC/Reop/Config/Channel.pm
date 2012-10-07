package Alpha::IRC::Reop::Config::Channel;

## Config for a single channel.

use Moo;
use strictures 1;

has 'delta' => (
  lazy    => 1,
  is      => 'ro',
  default => sub { 900 },
);

has 'key' => (
  lazy    => 1,
  is      => 'ro',
  default => sub { '' },
);

1;

=pod

=head1 NAME

IRC::Reop::Config::Channel

=head1 SYNOPSIS

  my $delta = $cfg_obj->channels->{ $chan }->delta;

=head1 DESCRIPTION

Configuration for a single channel.

=head2 delta

The allowable per-user idle delta for this channel.

=head2 key

A key needed to rejoin this channel.

=head1 AUTHOR

Jon Portnoy <avenj@cobaltirc.org>

=cut
