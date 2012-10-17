package Alpha::IRC::Reop::Plugin::Reclaim;
## POE::Component::IRC::Plugin::NickReclaim work-alike
##  ... except configurable altnicks

use Carp;
use strictures 1;

use IRC::Utils                  'parse_user';
use POE::Component::IRC::Plugin 'PCI_EAT_NONE';


sub new {
  my $class  = shift;
  my %params = @_;
  $params{lc $_} = delete $params{$_} for keys %params;

  my $self = {};
  bless $self, $class;

  $params{altnicks} = delete $params{alternates}
    if defined $params{alternates};
  $self->altnicks( $params{altnicks} ) if defined $params{altnicks};
  $self->delay( $params{delay} // $params{poll} // 30 );
  $self->suffix( $params{suffix} // '_' );

  $self
}

sub PCI_register {
  my ($self, $irc) = @_;
  $irc->plugin_register( $self, 'SERVER',
    qw/
      001
      433
      nick
      quit
    /,
  );

  $irc->plugin_register( $self, 'USER', 'nick' );

  $self->_want_nick( $irc->nick_name );

  1
}

sub PCI_unregister { 1 }

sub U_nick {
  my ($self, undef, $nref) = @_;
  my ($nick) = $$nref =~ /^NICK +(.+)/i;

  if (! defined $self->_temp_nick || $self->_temp_nick ne $nick) {
    $self->_clear_temp_nick;
    $self->_want_nick( $nick );
  }

  PCI_EAT_NONE
}

sub S_001 {
  my ($self, $irc) = splice @_, 0, 2;

  $self->is_reclaimed(
    $irc->nick_name eq $self->_want_nick ? 1 : 0
  );

  PCI_EAT_NONE
}

sub S_433 {
  ## NICKNAMEINUSE
  my ($self, $irc) = splice @_, 0, 2;
  my $target = ${ $_[2] }->[0];

  if ( !$irc->logged_in || $irc->nick_name eq $target) {
    ## FIXME
    ##  Need to try each altnick in sequence.
    ##  _temp_nick should be the nick we are currently trying?
    ##  Need to track which / how many we've tried.
    ##  If we've tried them all, then seen count matches
    ##  size of altnick array.
    ##  Resort to adding ->suffix.
    ##  yield a nick()
  }

  ## FIXME kill existing alarm id if we have one
  ##  set a new one for our delay via irc->delay()
  ##  send nick for our next target nick in ->delay() secs

  PCI_EAT_NONE
}

sub S_nick {
  my ($self, $irc) = splice @_, 0, 2;
  my $old = parse_user( ${ $_[0] } );
  my $new = ${ $_[1] };

  if ($new eq $irc->nick_name) {
    ## FIXME
    ##  If our new nick is our current _want_nick, we've is_reclaimed(1)
    ##  and can kill any pending nick change alarm
  } elsif ($old eq $self->_want_nick) {
    ## FIXME saw offender nick change, kill any pending alarm
    ## yield a nick change immediately
  }

  PCI_EAT_NONE
}

sub S_quit {
  my ($self, $irc) = splice @_, 0, 2;
  my $quitter = parse_user( ${ $_[0] } );

  if ($quitter eq $irc->nick_name) {
    ## FIXME we're gone, kill any pending alarm
  } elsif (!$self->is_reclaimed && $quitter eq $self->_want_nick) {
    ## FIXME kill any pending alarm, yield nick change immediately
  }
}


## Accessors.
sub altnicks {
  my ($self, $val) = @_;

  if (defined $val) {
    confess "altnicks() expected ARRAY"
      unless ref $val eq 'ARRAY';

    return $self->{_altnicks} = $val
  }

  $self->{_altnicks}
}

sub has_altnicks {
  my ($self) = @_;

  return unless ref $self->{_altnicks} eq 'ARRAY'
    and @{ $self->{_altnicks} };

  1
}

sub suffix {
  my ($self, $val) = @_;
  return $self->{_suffix} = $val if defined $val;
  $self->{_suffix}
}

sub delay {
  my ($self, $val) = @_;
  return $self->{_delay} = $val if defined $val;
  $self->{_delay}
}

sub _want_nick {
  my ($self, $val) = @_;
  return $self->{_wantnick} = $val if defined $val;
  $self->{_wantnick}
}

sub _temp_nick {
  my ($self, $val) = @_;
  return $self->{_tempnick} = $val if defined $val;
  $self->{_tempnick};
}

sub _clear_temp_nick {
  my ($self) = @_;
  delete $self->{_tempnick}
}

sub is_reclaimed {
  my ($self, $val) = @_;
  return $self->{_reclaimed} = $val if defined $val;
  $self->{_reclaimed}
}


no warnings 'void';
q{
 < avenj> joahisfurry.com
 < Joah> avenj is sleeping on the couch tonight :|
};


## FIXME
##  take array of alt nicks at construction time (optional)
##  take suffix to use if alt nicks in use / nonexistant
##   default to _
## otherwise act like POE::Component::IRC::Plugin::NickReclaim
