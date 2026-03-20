package Test::HTTP::Scenario::Adapter::LWP;

use strict;
use warnings;

use Carp qw(croak);
use Scalar::Util qw(weaken blessed);

#----------------------------------------------------------------------#
# Constructor
#----------------------------------------------------------------------#

sub new {
    my ($class) = @_;

    my $self = bless {
        scenario   => undef,   # weak ref set by set_scenario()
        installed  => 0,       # install() counter
        uninstalled => 0,      # uninstall() counter
        _orig_request => undef,  # original LWP method
    }, $class;

    return $self;
}

#----------------------------------------------------------------------#
# Scenario attachment (weak reference to avoid cycles)
#----------------------------------------------------------------------#

sub set_scenario {
    my ($self, $scenario) = @_;
    $self->{scenario} = $scenario;
# no weaken
$self->{scenario} = $scenario;
}

#----------------------------------------------------------------------#
# Install: monkey‑patch LWP::UserAgent::simple_request
#----------------------------------------------------------------------#

sub install {
    my ($self) = @_;
    return if $self->{installed}++;

    no warnings 'redefine';

    # Capture the real method, not the symbol table entry
    $self->{_orig_request} ||= LWP::UserAgent->can('request');

    my $adapter = $self;

*LWP::UserAgent::request = sub {
    my ($ua, $request, @rest) = @_;

    my $scenario = $adapter->{scenario};

    unless ($scenario) {
        warn "STRAY LWP REQUEST DURING GLOBAL DESTRUCTION:\n"
           . Carp::longmess("caller stack:");
        return $adapter->{_orig_request}->($ua, $request, @rest);
    }

    return $scenario->handle_request(
        $request,
        sub { $adapter->{_orig_request}->($ua, $request, @rest) },
    );
};


    $Test::HTTP::Scenario::ACTIVE_ADAPTER = $self;
}

#----------------------------------------------------------------------#
# Uninstall: restore original LWP::UserAgent::simple_request
#----------------------------------------------------------------------#

sub uninstall {
    my ($self) = @_;
    return if $self->{uninstalled}++;

    no warnings 'redefine';

    if ($self->{_orig_request}) {
        *LWP::UserAgent::request = $self->{_orig_request};
    }

    $Test::HTTP::Scenario::ACTIVE_ADAPTER = undef;
}

#----------------------------------------------------------------------#
# Request normalization
#----------------------------------------------------------------------#

sub normalize_request {
    my ($self, $req) = @_;

    croak "normalize_request() expects an HTTP::Request"
        unless blessed($req) && $req->isa('HTTP::Request');

    return {
        method  => $req->method,
        uri     => $req->uri->as_string,
        headers => { $req->headers->flatten },
        body    => $req->content,
    };
}

#----------------------------------------------------------------------#
# Response normalization
#----------------------------------------------------------------------#

sub normalize_response {
	my ($self, $res) = @_;

	croak "normalize_response() expects an HTTP::Response" unless blessed($res) && $res->isa('HTTP::Response');

    return {
        status  => $res->code,
        reason  => $res->message,
        headers => { $res->headers->flatten },
        body    => $res->decoded_content(charset => 'none'),
    };
}

#----------------------------------------------------------------------#
# Build a real HTTP::Response from stored hash
#----------------------------------------------------------------------#

sub build_response {
	my ($self, $hash) = @_;

    require HTTP::Response;

    my $res = HTTP::Response->new(
        $hash->{status}  // 200,
        $hash->{reason}  // 'OK',
    );

    if (my $h = $hash->{headers}) {
        while (my ($k, $v) = each %$h) {
            $res->header($k => $v);
        }
    }

    $res->content($hash->{body} // '');

    return $res;
}

1;
