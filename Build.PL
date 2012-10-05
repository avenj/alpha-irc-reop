#!/usr/bin/env perl

use Module::Build;
use strict; use warnings FATAL => 'all';

my $build = Module::Build->new(
  module_name   => 'Alpha::IRC::Reop',
  license       => 'perl',
  dist_abstract => 'Silly reop bot because I love Joah.',
  dist_author   => 'Fidel Castro <avenj@cobaltirc.org>',
  recursive_test_files => 1,
  create_readme => 1,
  create_makefile_pl => 'small',
  requires => {
    perl       => '5.10.1',
    Carp       => 0,

    strictures              => 1,
    indirect                => 0,
    multidimensional        => 0,
    'bareword::filehandles' => 0,

    Moo                   => 1,
    'namespace::clean'    => '0.23',

    'IRC::Utils'          => 0,
    'POE'                 => '1.3',
    'POE::Component::IRC' => '6.80',

    'Proc::PID::File'     => 0,

    'YAML::XS'            => 0,
  },
);

$build->create_build_script;

__END__
Pie.
