use strict;
use File::ShareDir;
use HTTP::Request;
use Test::More;
use Digest::MD5;
use t::TestUtils;

$Plack::Test::Impl = "Server";
$ENV{PLACK_SERVER} = 'Springbok';

my $file = File::ShareDir::dist_dir('Plack') . "/baybridge.jpg";

my $app = sub {
    my $env = shift;
    my $body;
    my $clen = $env->{CONTENT_LENGTH};
    while ($clen > 0) {
        $env->{'psgi.input'}->read(my $buf, $clen) or last;
        $clen -= length $buf;
        $body .= $buf;
    }
    return [ 200, [ 'Content-Type', 'text/plain', 'X-Content-Length', $env->{CONTENT_LENGTH} ], [ $body ] ];
};

test_psgi $app, sub {
    my $cb = shift;

    open my $fh, "<:raw", $file;
    local $/ = \1024;

    my $req = HTTP::Request->new(POST => "http://localhost/");
    $req->content(sub { scalar <$fh> });

    my $res = $cb->($req);
    is $res->code, 200;
    ok($res->header('X-Content-Length') ==  79838 || $res->header('X-Content-Length') || 14750);
    ok( Digest::MD5::md5_hex($res->content) eq '983726ae0e4ce5081bef5fb2b7216950' || Digest::MD5::md5_hex($res->content) eq '70546a79c7abb9c497ca91730a0686e4');
};

done_testing;
