package Test::HTTP::Scenario;

use strict;
use warnings;
use Carp qw(croak carp);
use Exporter qw(import);
use Scalar::Util qw(blessed);
use File::Slurper qw(read_text write_text);

our @EXPORT_OK = qw(with_http_scenario);

#----------------------------------------------------------------------#
# Constructor
#----------------------------------------------------------------------#

sub new {
    my ($class, %args) = @_;

    # Entry: class name and argument hash
    # Exit:  new Test::HTTP::Scenario object
    # Side effects: loads adapter and serializer classes
    # Notes: mode must be explicit and valid

    for my $k (qw(name file mode adapter)) {
        croak "Missing required argument '$k'" unless exists $args{$k};
    }

    croak "Invalid mode '$args{mode}'"
        unless $args{mode} =~ /\A(?:record|replay)\z/;

my $adapter = _build_adapter($args{adapter});
    
    my $serializer = _build_serializer($args{serializer} || 'YAML');

    my $self = bless {
        name         => $args{name},
        file         => $args{file},
        mode         => $args{mode},
        adapter      => $adapter,
        serializer   => $serializer,
        interactions => [],
        loaded       => 0,
        diffing      => $args{diffing} // 1,
        strict       => $args{strict}  // 0,
	_cursor => 0
    }, $class;

    $adapter->set_scenario($self);

    return $self;
}

#----------------------------------------------------------------------#
# Public API
#----------------------------------------------------------------------#

sub run {
    my ($self, $code) = @_;

    my $adapter = $self->{adapter};
    $adapter->set_scenario($self);

    $self->_load_if_needed;
    $adapter->install;

    # ensure uninstall + save ALWAYS run
    my $guard = Test::HTTP::Scenario::Guard->new(sub {
        $adapter->uninstall;
        $self->_save_if_needed;
    });

    my $wantarray = wantarray;

    my (@ret, $ret);

    # *** NO eval here ***
    if (!defined $wantarray) {
        $code->();
    }
    elsif ($wantarray) {
        @ret = $code->();
    }
    else {
        $ret = $code->();
    }

    # strict mode AFTER callback, BEFORE returning
    if ($self->{mode} eq 'replay' && $self->{strict}) {
        my $total  = @{ $self->{interactions} || [] };
        my $cursor = $self->{_cursor} // 0;

        if ($cursor < $total) {
            croak "Strict mode: $total interactions recorded, "
                . "but only $cursor were used";
        }
    }

    return undef      if !defined $wantarray;
    return @ret       if $wantarray;
    return $ret;
}


sub with_http_scenario {
    my @args = @_;

    # Entry: key/value arguments followed by coderef
    # Exit:  returns whatever the coderef returns
    # Side effects: constructs a scenario and runs it
    # Notes: convenience wrapper for tests

    my $code = @args && ref $args[-1] eq 'CODE' ? pop @args : undef;

    croak 'with_http_scenario() requires a coderef as last argument'
        unless $code;

    my %args = @args;

    my $self = __PACKAGE__->new(%args);

    return $self->run($code);
}

sub handle_request {
	my ($self, $req, $do_real) = @_;

    croak 'handle_request() requires a coderef for real request'
        unless ref $do_real eq 'CODE';

    if ($self->{mode} eq 'record') {
        my $res = $do_real->();

        my $record = {
            request  => $self->_normalize_request($req),
            response => $self->_normalize_response($res),
        };

        push @{ $self->{interactions} }, $record;

        return $res;
    }

    # replay mode
    $self->_load_if_needed;

    my $idx = $self->{_cursor} // 0;
    my $interactions = $self->{interactions} || [];

    if ($idx > $#$interactions) {
        croak 'No more recorded HTTP interactions available in scenario';
    }

    my $expected = $interactions->[$idx]{request}  || {};
    my $stored   = $interactions->[$idx]{response} || {};

    my $got = $self->_normalize_request($req);

    my $match = $self->_requests_match($expected, $got);

    if (!$match) {
        my $msg = 'No matching HTTP interaction found in scenario';

        if ($self->{diffing}) {
            my $diff = $self->_request_diff_string($expected, $got, $idx);
            $msg .= "\n$diff";
        }

        croak $msg;
    }
    
	# consume this interaction
	$self->{_cursor}++;

	return $self->_denormalize_response($stored);
}

#----------------------------------------------------------------------#
# Internal helpers
#----------------------------------------------------------------------#

sub _build_adapter {
	my $adapter = $_[0];

    # Entry: adapter name or object
    # Exit:  adapter object
    # Side effects: may load adapter class
    # Notes: supports LWP, HTTP_Tiny and Mojo by name

    if (blessed $adapter) {
        return $adapter;
    }

    my %map = (
        LWP       => 'Test::HTTP::Scenario::Adapter::LWP',
        HTTP_Tiny => 'Test::HTTP::Scenario::Adapter::HTTP_Tiny',
        Mojo      => 'Test::HTTP::Scenario::Adapter::Mojo',
    );

    my $class = $map{$adapter}
        or croak "Unknown adapter '$adapter'";

    eval "require $class" or croak "Failed to load $class: $@";

    return $class->new;
}

sub _build_serializer {
    my ($name) = @_;

    # Entry: serializer name
    # Exit:  serializer object
    # Side effects: may load serializer class
    # Notes: supports YAML and JSON by name

    my %map = (
        YAML => 'Test::HTTP::Scenario::Serializer::YAML',
        JSON => 'Test::HTTP::Scenario::Serializer::JSON',
    );

    my $class = $map{$name}
        or croak "Unknown serializer '$name'";

    eval "require $class" or croak "Failed to load $class: $@";

    return $class->new;
}

sub _load_if_needed {
    my ($self) = @_;

    # Entry: scenario object
    # Exit:  interactions populated if replay mode and file exists
    # Side effects: reads from filesystem
    # Notes: idempotent and only active in replay mode

    return if $self->{loaded};
    return if $self->{mode} ne 'replay';

    return unless -e $self->{file};

    my $text = read_text($self->{file});
    my $data = $self->{serializer}->decode_scenario($text);

    $self->{interactions} = $data->{interactions} || [];
    $self->{loaded}       = 1;

    return;
}

sub _save_if_needed {
    my ($self) = @_;

    # Entry: scenario object
    # Exit:  fixtures written if record mode
    # Side effects: writes to filesystem
    # Notes: diffing and strict behaviour can be added later

    return if $self->{mode} ne 'record';

    my $data = {
        name         => $self->{name},
        version      => 1,
        interactions => $self->{interactions},
    };

    my $text = $self->{serializer}->encode_scenario($data);

    write_text($self->{file}, $text);

    return;
}

sub _normalize_request {
    my ($self, $req) = @_;

    # Entry: adapter specific request object
    # Exit:  normalized request hash
    # Side effects: none
    # Notes: delegates to adapter

    return $self->{adapter}->normalize_request($req);
}

sub _normalize_response {
    my ($self, $res) = @_;

    # Entry: adapter specific response object
    # Exit:  normalized response hash
    # Side effects: none
    # Notes: delegates to adapter

    return $self->{adapter}->normalize_response($res);
}

sub _denormalize_response {
    my ($self, $hash) = @_;

    # Entry: normalized response hash
    # Exit:  adapter specific response object
    # Side effects: none
    # Notes: delegates to adapter

    return $self->{adapter}->build_response($hash);
}

sub _find_match {
    my ($self, $req) = @_;

    # Entry: adapter specific request object
    # Exit:  matching interaction hash or undef
    # Side effects: none
    # Notes: simple method and uri equality for now

    my $norm = $self->_normalize_request($req);

    for my $interaction (@{ $self->{interactions} || [] }) {
        my $r = $interaction->{request} || {};

        next unless ($r->{method} || '') eq ($norm->{method} || '');
        next unless ($r->{uri}    || '') eq ($norm->{uri}    || '');

        return $interaction;
    }

    return;
}

sub _requests_match {
    my ($self, $exp, $got) = @_;

    return 0 unless ($exp->{method} || '') eq ($got->{method} || '');
    return 0 unless ($exp->{uri}    || '') eq ($got->{uri}    || '');

    # you can extend this later to headers/body if desired
    return 1;
}

sub _request_diff_string {
    my ($self, $exp, $got, $idx) = @_;

    require Data::Dumper;
    local $Data::Dumper::Terse  = 1;
    local $Data::Dumper::Indent = 1;

    return
      "HTTP interaction mismatch at index $idx:\n"
    . "  Expected method: $exp->{method}\n"
    . "       Got method: $got->{method}\n"
    . "  Expected uri:    $exp->{uri}\n"
    . "       Got uri:    $got->{uri}\n"
    . "  Expected request hash:\n"
    . Data::Dumper::Dumper($exp)
    . "  Got request hash:\n"
    . Data::Dumper::Dumper($got);
}

{
    package Test::HTTP::Scenario::Guard;
    sub new {
        my ($class, $cb) = @_;
        bless $cb, $class;
    }
    sub DESTROY {
        my ($self) = @_;
        $self->();
    }
}


1;

__END__

=head1 NAME

Test::HTTP::Scenario - Record and replay HTTP interactions for deterministic tests

=head1 SYNOPSIS

  use Test::Most;
  use Test::HTTP::Scenario qw(with_http_scenario);

  with_http_scenario(
      name    => 'get_user_basic',
      file    => 't/fixtures/get_user_basic.yaml',
      mode    => 'replay',
      adapter => 'LWP',
      sub {
          my $user = $client->get_user(42);
          cmp_deeply($user, superhashof({ id => 42 }));
      },
  );

=head1 DESCRIPTION

Test::HTTP::Scenario provides a record and replay mechanism for HTTP
interactions so that tests for API clients can run deterministically
without depending on live network access.

It works by installing temporary hooks into supported HTTP client
libraries, capturing requests and responses in record mode, and
replaying them from fixture files in replay mode.

=head2 API specification

=head3 Input

=head4 new

Schema compatible with Params::Validate::Strict:

=over 4

=item * name (Str, required)

Scenario name.

=item * file (Str, required)

Path to the fixture file.

=item * mode (Str, required)

Either C<record> or C<replay>.

=item * adapter (Str|Object, required)

Adapter name such as C<LWP> or an adapter object.

=item * serializer (Str, optional)

Serializer name, default C<YAML>.

=item * diffing (Bool, optional)

Enable or disable diffing, default true.

=item * strict (Bool, optional)

Enable or disable strict behaviour, default false.

=back

=head4 with_http_scenario

Same as C<new>, passed as key value pairs, followed by a coderef.

=head3 Output

=head4 new

Schema compatible with Returns::Set:

=over 4

=item * object

A L<Test::HTTP::Scenario> instance.

=back

=head4 with_http_scenario

Returns whatever the supplied coderef returns, in the same context.

=head1 METHODS

=head2 new

Constructs a new scenario object. See L</API specification> for
arguments and return values.

=head2 run

Runs a coderef under the control of the scenario. Installs adapter
hooks, loads fixtures in replay mode, and saves fixtures in record
mode.

=head2 with_http_scenario

Convenience wrapper that constructs a scenario and immediately calls
C<run> with the supplied coderef.

=head2 handle_request

Called by adapters to either perform a real HTTP request in record
mode or to replay a stored response in replay mode.

=head1 SIDE EFFECTS

This module reads from and writes to fixture files on disk and
temporarily modifies behaviour of supported HTTP client libraries
through adapter modules.

=head1 NOTES

This module is intended for use in test suites and should not be used
in production code paths.

=head1 EXAMPLE

See the SYNOPSIS for a basic example of using C<with_http_scenario>
with an API client.

=cut
