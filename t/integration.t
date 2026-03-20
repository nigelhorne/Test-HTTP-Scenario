use strict;
use warnings;

use Test::Most;
# use Test::Warnings;
# use Test::Strict;
# use Test::Vars;
# use Test::Deep;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::HTTP::Scenario;
use Test::HTTP::Scenario::Adapter::LWP;   # <-- add this
use LWP::UserAgent;
use HTTP::Server::Simple::CGI;

BEGIN {
    require File::Path;
    File::Path::make_path('t/fixtures');
}

local $SIG{__WARN__} = sub {
    diag "WARNING DURING REPLAY: @_";
};

my $orig_request = LWP::UserAgent->can('request');

{
    package Local::HTTP::Server;
    use strict;
    use warnings;
    use parent 'HTTP::Server::Simple::CGI';

    sub handle_request {
        my ($self, $cgi) = @_;
        my $path = $cgi->path_info || '/';

        print "HTTP/1.0 200 OK\r\n";
        print "Content-Type: text/plain\r\n\r\n";

        print $path eq '/hello' ? "hello world" : "unknown";
    }
}

my $PORT = 50080;
my $URL  = "http://127.0.0.1:$PORT/hello";

sub _start_server {
    my $pid = fork();
    BAIL_OUT("fork failed") unless defined $pid;

    if ($pid == 0) {
        my $server = Local::HTTP::Server->new($PORT);
        $server->run;
        exit 0;
    }

    sleep 1;
    return $pid;
}

sub _stop_server {
    my ($pid) = @_;
    kill 'TERM', $pid if $pid;
    waitpid $pid, 0;
}

#----------------------------------------------------------------------#
# Record
#----------------------------------------------------------------------#

subtest 'record scenario from local HTTP server' => sub {
    my $pid = _start_server();
    my $ua  = LWP::UserAgent->new;

    my $file = 't/fixtures/integration_hello.yaml';
    unlink $file if -e $file;

    my $adapter = Test::HTTP::Scenario::Adapter::LWP->new;   # <-- create adapter

    my $sc = Test::HTTP::Scenario->new(
        name    => 'integration_hello',
        file    => $file,
        mode    => 'record',
        adapter => $adapter,                                  # <-- pass object
    );

    $sc->run(sub {
        my $res = $ua->get($URL);
        ok $res->is_success;
        is $res->decoded_content, 'hello world';
    });

    $sc->_save_if_needed;

    ok -e $file, 'fixture file written';

    _stop_server($pid);
};

#----------------------------------------------------------------------#
# Replay
#----------------------------------------------------------------------#

subtest 'replay scenario without server' => sub {
    my $ua  = LWP::UserAgent->new;
    my $file = 't/fixtures/integration_hello.yaml';

    ok -e $file, 'fixture exists';

    my $adapter = Test::HTTP::Scenario::Adapter::LWP->new;   # <-- new adapter

    my $sc = Test::HTTP::Scenario->new(
        name    => 'integration_hello',
        file    => $file,
        mode    => 'replay',
        adapter => $adapter,                                  # <-- pass object
    );

    $sc->run(sub {
        my $res = $ua->get($URL);
        ok $res->is_success;
        is $res->decoded_content, 'hello world';
    });

    # let $sc and $adapter go out of scope here
};

#----------------------------------------------------------------------#
# GLOBAL TEARDOWN
#----------------------------------------------------------------------#

is(
    LWP::UserAgent->can('request'),
    $orig_request,
    'LWP::UserAgent::request restored after all scenarios'
);

done_testing;
