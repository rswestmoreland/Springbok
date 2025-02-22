use strict;
use warnings;
use HTTP::Request::Common;
use Test::More;
use t::TestUtils;

$Plack::Test::Impl = 'Server';
$ENV{PLACK_SERVER} = 'Springbok';

test_psgi
    app => sub {
        my $env = shift;
        return [ 200, [ 'Content-Type' => 'text/plain' ], [$$] ];
    },
    client => sub {
        my %seen_pid;
        my $cb = shift;
        for (1..23) {
            my $res = $cb->(GET "/");
            $seen_pid{$res->content}++;
        }
        cmp_ok(keys(%seen_pid), '<=', 10, 'In non-harakiri mode, pid is reused')
    };

test_psgi
    app => sub {
        my $env = shift;
        $env->{'psgix.harakiri.commit'} = $env->{'psgix.harakiri'};
        return [ 200, [ 'Content-Type' => 'text/plain' ], [$$] ];
    },
    client => sub {
        my %seen_pid;
        my $cb = shift;
        for (1..23) {
            my $res = $cb->(GET "/");
            $seen_pid{$res->content}++;
        }
        is keys(%seen_pid), 23, 'In Harakiri mode, each pid only used once';
        sleep 1;
    };

done_testing;
