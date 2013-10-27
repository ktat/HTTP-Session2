package HTTP::Session2::ClientStore;
use strict;
use warnings;
use utf8;
use 5.008_001;

use Cookie::Baker ();
use Storable ();
use MIME::Base64 ();
use Digest::HMAC;

use Mouse;

extends 'HTTP::Session2::Base';

has serializer => (
    is => 'ro',
    default => sub {
        sub {
            MIME::Base64::encode(Storable::nfreeze($_[0]), '' )
        }
    },
);

has deserializer => (
    is => 'ro',
    default => sub {
        sub {Storable::thaw(MIME::Base64::decode($_[0]))}
    },
);

has ignore_old => (
    is => 'ro',
);

no Mouse;

sub _compare {
    my ( $s1, $s2 ) = @_;

    return unless defined $s2;
    return if length $s1 != length $s2;
    my $r = 0;
    for my $i ( 0 .. length($s1) - 1 ) {
        $r |= ord( substr $s1, $i ) ^ ord( substr $s2, $i );
    }

    return $r == 0;
}

sub sig {
    my($self, $b64) = @_;
    $self->secret or die "Missing secret. ABORT";
    Digest::HMAC::hmac_hex($b64, $self->secret, $self->hmac_function);
}

sub load_session {
    my $self = shift;

    # Load from cookie.
    my $cookies = Cookie::Baker::crush_cookie($self->env->{HTTP_COOKIE});
    my $session_cookie = $cookies->{$self->session_cookie->{name}};
    if (defined $session_cookie) {
        my ($time, $id, $serialized, $sig) = split /:/, $session_cookie, 4;
        _compare($self->sig($serialized), $sig) or do {
            return;
        };

        if (defined $self->ignore_old) {
            if ($time < $self->ignore_old()) {
                return;
            }
        }

        my $data = $self->deserializer->($serialized);
        $self->{id}    = $id;
        $self->{_data} = $data;
        return 1;
    }
}

sub create_session {
    my $self = shift;

    $self->{id}    = $self->_generate_session_id();
    $self->{_data} = +{};
}

sub _generate_session_id {
    substr(Digest::SHA::sha1_hex(rand() . $$ . {} . time),int(rand(4)),31);
}

sub regenerate_id {
    my ($self) = @_;

    # Load original session first.
    $self->load_session();

    # Create new session.
    $self->{id}    = $self->_generate_session_id();
    $self->is_dirty(1);
    $self->necessary_to_send(1);
}

sub xsrf_token {
    my $self = shift;
    return $self->id;
}

sub expire {
    my $self = shift;

    # Load original session first.
    $self->load_session();

    # Rebless to expired object.
    bless $self, 'HTTP::Session2::ClientStore::Expired';

    return;
}

sub make_cookies {
    my ($self) = @_;

    return unless $self->necessary_to_send || $self->is_dirty;

    my @cookies;

    # Finalize session cookie
    {
        my %cookie = %{$self->session_cookie};
        my $name = delete $cookie{name};
        my $value = $self->_serialize($self->id, $self->_data);
        push @cookies, $name => +{
            %cookie,
            value => $value,
        };
    }

    # Finalize XSRF cookie
    {
        my %cookie = %{$self->xsrf_cookie};
        my $name = delete $cookie{name};
        push @cookies, $name => +{
            %cookie,
            value => $self->id,
        };
    }

    return @cookies;
}

sub _serialize {
    my ($self, $id, $data) = @_;

    my $serialized = $self->serializer->($data);
    join ":", time(), $id, $serialized, $self->sig($serialized);
}

package HTTP::Session2::ClientStore::Expired;
use parent qw(HTTP::Session2::Base);

sub set    { Carp::croak("You cannot set anything to expired session") }
sub get    { Carp::croak("You cannot get anything from expired session") }
sub remove { Carp::croak("You cannot remove anything from expired session") }

sub make_cookies {
    my ($self, $res) = @_;

    my @cookies;

    # Finalize session cookie
    {
        my %cookie = %{$self->session_cookie};
        my $name = delete $cookie{name};
        push @cookies, $name => +{
            %cookie,
            value => '',
            expires => '-1d',
        };
    }

    # Finalize XSRF cookie
    {
        my %cookie = %{$self->xsrf_cookie};
        my $name = delete $cookie{name};
        push @cookies, $name => +{
            %cookie,
            value => '',
            expires => '-1d',
        };
    }

    return @cookies;
}

1;
__END__

=head1 NAME

=head1 DESCRIPTION

This is a part of L<HTTP::Session2> library.

This module stores the data to the cookie value.
