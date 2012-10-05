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
