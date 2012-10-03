package Alpha::IRC::Reop::Config;

use Carp;
use 5.10.1;

use Moo;
use strictures 1;


has 'nickname' => (
  required  => 1,
  is        => 'ro',
  writer    => 'set_nickname',
  predicate => 1,
);

has 'server' => (
  required  => 1,
  is        => 'ro',
  writer    => 'set_server',
  predicate => 1,
);

has 'channels' => (
  ## FIXME class for channel-specific settings?
  required  => 1,
  is        => 'ro',
  writer    => 'set_channels',
  predicate => 1,
);

has 'status_modes' => (
  is        => 'ro',
  writer    => 'set_status_modes',
  predicate => 1,
);

1;
