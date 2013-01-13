package Alpha::IRC::Reop::Config;

use Carp;
use 5.10.1;

use Moo;

use YAML::XS   'LoadFile';
use IRC::Utils 'lc_irc';

use Alpha::IRC::Reop::Config::Channel;

use Data::Dumper;
use File::Spec;

use namespace::clean;

## Nick/ident/gecos
has 'nickname' => (
  required  => 1,
  is        => 'ro',
  writer    => 'set_nickname',
  predicate => 1,
);

has 'username' => (
  lazy      => 1,
  is        => 'ro',
  writer    => 'set_username',
  predicate => 1,
  default   => sub { 'reop' },
);

has 'realname' => (
  lazy      => 1,
  is        => 'ro',
  writer    => 'set_realname',
  predicate => 1,
  default   => sub { 'Alpha-IRC-Reop' },
);

## Server opts
has 'server' => (
  required  => 1,
  is        => 'ro',
  writer    => 'set_server',
  predicate => 1,
);

has 'bindaddr' => (
  lazy      => 1,
  is        => 'ro',
  writer    => 'set_bindaddr',
  predicate => 1,
);

has 'ipv6' => (
  lazy      => 1,
  is        => 'ro',
  writer    => 'set_ipv6',
  predicate => 1,
  default   => sub { 0 },
);

has 'password' => (
  lazy      => 1,
  is        => 'ro',
  writer    => 'set_password',
  predicate => 1,
);

has 'port' => (
  required  => 1,
  is        => 'ro',
  writer    => 'set_port',
  predicate => 1,
  default   => sub { 6667 },
);

has 'ssl' => (
  lazy      => 1,
  is        => 'ro',
  writer    => 'set_ssl',
  predicate => 1,
  default   => sub { 0 },
);

has 'umode' => (
  lazy      => 1,
  is        => 'ro',
  writer    => 'set_umode',
  predicate => 1,
  default   => sub { '+i' },
);

## Misc
has 'nickserv_pass' => (
  lazy      => 1,
  is        => 'ro',
  writer    => 'set_nickserv_pass',
  predicate => 1,
);


has 'channels' => (
  required  => 1,
  is        => 'ro',
  writer    => 'set_channels',
  predicate => 1,
);


## Reop / up / down sequences
## ARRAY of commands to execute for certain events
## Each line is passed channel and nickname respectively & fed to sprintf

has 'limiter_count' => (
  lazy      => 1,
  is        => 'ro',
  writer    => 'set_limiter_count',
  predicate => 1,
  default   => sub { 5 },
);

has 'limiter_secs' => (
  lazy      => 1,
  is        => 'ro',
  writer    => 'set_limiter_secs',
  predicate => 1,
  default   => sub { 3 },
);

has 'reop_sequence' => (
  ## Regain op for ourself.
  lazy      => 1,
  is        => 'ro',
  writer    => 'set_reop_sequence',
  predicate => 1,
);

has 'up_sequence' => (
  ## Re-up an active operator.
  lazy      => 1,
  is        => 'ro',
  writer    => 'set_up_sequence',
  predicate => 1,
);

has 'down_sequence' => (
  ## Downgrade inactive operator.
  lazy      => 1,
  is        => 'ro',
  writer    => 'set_down_sequence',
  predicate => 1,
);

has 'excepted' => (
  lazy      => 1,
  is        => 'ro',
  writer    => 'set_excepted',
  predicate => 1,
  default   => sub {  []  },
);

has 'from_file_path' => (
  lazy      => 1,
  is        => 'ro',
  writer    => 'set_from_file_path',
  predicate => 1,
  default   => sub { () },
);


sub dumped {
  my ($self) = @_;
  Dumper($self)
}


sub normalize_channels {
  my ($self, $casemap) = @_;
  for my $channel (keys %{ $self->channels }) {
    $self->channels->{ lc_irc($channel, $casemap) }
      = delete $self->channels->{$channel}
  }
}


sub from_file {
  my ($class, $path) = @_;

  my $cfg = LoadFile($path) || confess "LoadFile failed";

  confess "Config not a HASH" unless ref $cfg eq 'HASH';

  my %opts = ( channels => {} );

  for my $toplevel (qw/Local Remote Channels/) {
    confess "Missing/unparsable required top-level directive $toplevel"
      unless ref $cfg->{$toplevel} eq 'HASH';
  }

  if (ref $cfg->{Excepted} eq 'ARRAY') {
    $opts{excepted} = $cfg->{Excepted}
  }

  ## Can shove validation bits here.
  for my $local (keys %{ $cfg->{Local} }) {
    $opts{lc $local} = delete $cfg->{Local}->{$local}
      if defined $cfg->{Local}->{$local};
  }

  for my $remote (keys %{ $cfg->{Remote} }) {
    $opts{lc $remote} = delete $cfg->{Remote}->{$remote}
      if defined $cfg->{Remote}->{$remote};
  }

  for my $channel (keys %{ $cfg->{Channels} }) {
    unless (ref $cfg->{Channels}->{$channel} eq 'HASH') {
      $cfg->{Channels}->{$channel} = {};
    }

    my $chan_obj = Alpha::IRC::Reop::Config::Channel->new(
      ( $cfg->{Channels}->{$channel}->{delta} ?
         (delta => $cfg->{Channels}->{$channel}->{delta}) : ()
      ),
      ( $cfg->{Channels}->{$channel}->{key} ?
         (key => $cfg->{Channels}->{$channel}->{key}) : ()
      ),
    );

    $opts{channels}->{$channel} = $chan_obj
  }

  if (ref $cfg->{RateLimit} eq 'HASH') {
    $opts{limiter_count} = $cfg->{RateLimit}->{Count}
      if $cfg->{RateLimit}->{Count};

    $opts{limiter_secs} = $cfg->{RateLimit}->{Secs}
      if $cfg->{RateLimit}->{Secs};
  }

  if (ref $cfg->{Sequences} eq 'HASH') {
    TYPE: for my $type (keys %{ $cfg->{Sequences} }) {
      confess "Sequences -> $type not an ARRAY"
        unless ref $cfg->{Sequences}->{$type} eq 'ARRAY';

      SEQ: {
        if ($type eq 'ReopSelf') {
          $opts{reop_sequence} = delete $cfg->{Sequences}->{$type};
          last SEQ
        }

        if ($type eq 'UpUser') {
          $opts{up_sequence} = delete $cfg->{Sequences}->{$type};
          last SEQ
        }

        if ($type eq 'DownUser') {
          $opts{down_sequence} = delete $cfg->{Sequences}->{$type};
          last SEQ
        }

        confess "Unknown directive $type in Sequences"
      } # SEQ
    } # TYPE
  }

  my $fullpath = File::Spec->rel2abs($path);
  $class->new(from_file_path => $fullpath, %opts)
}

sub dump_example {
  my ($self) = @_;
  my @example = readline(DATA);
  join '', @example;
}

1;

=pod

=head1 NAME

Alpha::IRC::Reop::Config - Alpha::IRC::Reop configuration class

=head1 SYNOPSIS

  my $cfg_obj = Alpha::IRC::Reop::Config->from_file( $cfg_path );

  my $example_cf_file = Alpha::IRC::Reop::Config->dump_example;

  ## Create example conf from a shell:
  $ perl -MAlpha::IRC::Reop::Config -e \
     'print Alpha::IRC::Reop::Config->dump_example' \
      >> example.cf

  ## Details on starting the bot from a shell:
  $ alpha-irc-reop --help

=head1 DESCRIPTION

Provides YAML configuration file load facilities and configuration
accessors.

=head2 Attributes

Readable attributes (at least vaguely matching example configuration file):

  ## Scalar-type
  nickname
  username
  realname
  server
  bindaddr
  ipv6
  password
  port
  ssl
  nickserv_pass

  ## Array-type
  ## (Each line parsed via sprintf($line, $channel, $nick)
  ## at execution time)
  reop_sequence
  up_sequence
  down_sequence

B<set_$attrib> writers are provided for all of these.

=head2 Methods

=head3 channels

Retrieves the hash containing L<Alpha::IRC::Reop::Config::Channel> objects,
keyed on lowercased channel name.

=head3 dump_example

Returns an example YAML configuration file as a string.

=head3 dumped

Returns the L<Data::Dumper> dumped object, same as calling 
Dumper($cfg_obj).

=head3 normalize_channels

Normalize the L</channels> hash after retrieving the server's casemap
value. Takes a casemap (rfc1459, strict-rfc1459, ascii). Should be called
in an 'irc_001' handler or similar.

=head1 AUTHOR

Jon Portnoy <avenj@cobaltirc.org> per specifications set forth by Joah &
AlphaChat staff <admin@alphachat.net>

=cut

__DATA__
## Example config
---
Local:
  Nickname: "AlphaReop"
  Username: "alpha"
  Realname: "reop bot"

Remote:
  Server: "irc.alphachat.net"
  Port: 6667
  BindAddr: ~
  SSL: 0
  IPv6: 0
  Password: ~
  NickServ_Pass: "somepassword"
  UMode: "+i"

Channels:
  '#lobby':
    delta: 900
    key: ~

Excepted:
  ## A list of nicknames that will not be deopped.
  ## (Examples prefixed with digits to make them invalid nicks.)
  - "0spork"
  - "1avenj"

RateLimit:
  ## Allow 'Count' sequence lines in 'Secs' secs
  Count: 5
  Secs: 3

## Comment / remove Sequences to just use batched MODEs
Sequences:
  ## Passed channel and nickname respectively
  ReopSelf:
    - PRIVMSG ChanServ :OP %s %s

  UpUser:
    - PRIVMSG ChanServ :OP %s %s
    - PRIVMSG ChanServ :DEVOICE %s %s

  DownUser:
    - PRIVMSG ChanServ :DEOP %s %s
    - PRIVMSG ChanServ :VOICE %s %s
