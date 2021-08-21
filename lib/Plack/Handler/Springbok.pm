package Plack::Handler::Springbok;

use 5.16.3;
use strict;
use warnings;
use IO::Socket::IP;
use Plack::Util;
use Stream::Buffered;
use POSIX qw(EINTR EAGAIN EWOULDBLOCK);
use Socket qw(IPPROTO_TCP TCP_NODELAY);
use Parallel::Prefork;
use Server::Starter ();
use Guard;
use Crypt::Random::Seed;

our $VERSION = "0.49";

use XSLoader;
XSLoader::load(__PACKAGE__, $VERSION);

use constant MAX_REQUEST_SIZE => 131072;
use constant CHUNKSIZE        => 64 * 1024;

my $null_io = do { open my $io, "<", \""; $io };
my $bad_response = [ 400, [ 'Content-Type' => 'text/plain', 'Connection' => 'close' ], [ 'Bad Request' ] ];

sub new {
    my( $class, %args ) = @_;

    # setup before instantiation
    if ( $args{listen_sock} ) {
        $args{host} = $args{listen_sock}->sockhost;
        $args{port} = $args{listen_sock}->sockport;
    }
    elsif ( defined $ENV{SERVER_STARTER_PORT} ) {
        my ( $hostport, $fd ) = %{Server::Starter::server_ports()};

        if ( $hostport =~ /(.*):(\d+)/ ) {
            $args{host} = $1;
            $args{port} = $2;
        }
        else {
            $args{port} = $hostport;
        }

        $args{listen_sock} = IO::Socket::IP->new(
            Proto => 'tcp',
        ) or die "failed to create socket:$!";

        $args{listen_sock}->fdopen($fd, 'w')
            or die "failed to bind to listening socket:$!";
    }

    my $max_workers = 10;
    foreach ( qw(max_workers workers) ) {
        $max_workers = delete $args{$_}
            if defined $args{$_};
    }

    if ( $args{child_exit} ) {
        $args{child_exit} = eval $args{child_exit} unless ref($args{child_exit});
        die "child_exit is defined but not a code block" if ref($args{child_exit}) ne 'CODE';
    }

    my $self = bless {
        server_software      => $args{server_software} || $class,
        server_ready         => $args{server_ready} || sub {},
        listen_sock          => $args{listen_sock},
        host                 => $args{host} || 0,
        port                 => $args{port} || 8080,
        timeout              => $args{timeout} || 300,
        max_workers          => $max_workers,
        child_exit           => $args{child_exit} || sub {},
        min_reqs_per_child   => (
            defined $args{min_reqs_per_child}
            ? $args{min_reqs_per_child} : undef,
        ),
        max_reqs_per_child   => (
            $args{max_reqs_per_child} || $args{max_requests} || 1000,
        ),
        spawn_interval       => $args{spawn_interval} || 0,
        err_respawn_interval => (
            defined $args{err_respawn_interval}
            ? $args{err_respawn_interval} : undef,
        ),
    }, $class;

    $self;
}

sub setup_listener {
    my $self = shift;

    $self->{listen_sock} ||= IO::Socket::IP->new(
        Listen    => SOMAXCONN,
        LocalPort => $self->{port},
        LocalAddr => $self->{host},
        Proto     => 'tcp',
        ReuseAddr => 1,
    ) or die "failed to listen to port $self->{port}:$!";

    my $family = Socket::sockaddr_family(getsockname($self->{listen_sock}));
    $self->{_listen_sock_is_tcp} = $family != AF_UNIX;

    # set defer accept
    if ( $^O eq 'linux' && $self->{_listen_sock_is_tcp} ) {
        setsockopt($self->{listen_sock}, IPPROTO_TCP, 9, 1);
    }

    $self->{server_ready}->($self);
}


sub run {
    my( $self, $app ) = @_;

    $self->setup_listener();

    # use Parallel::Prefork
    my %pm_args = (
        max_workers => $self->{max_workers},
        trap_signals => {
            HUP  => 'TERM',
        },
    );

    if ( defined $self->{spawn_interval} ) {
        $pm_args{trap_signals}{USR1} = [ 'TERM', $self->{spawn_interval} ];
        $pm_args{spawn_interval} = $self->{spawn_interval};
    }

    if ( defined $self->{err_respawn_interval} ) {
        $pm_args{err_respawn_interval} = $self->{err_respawn_interval};
    }

    my $pm = Parallel::Prefork->new(\%pm_args);

    local $SIG{TERM} = sub {
        #tell the socket we're done reading (stops new connections, existing will continue)
        $self->{listen_sock}->shutdown(0)
          if not defined $ENV{SERVER_STARTER_PORT};

        $pm->signal_received('TERM');
        $pm->signal_all_children('TERM');
    };

    while ( $pm->signal_received !~ /^(TERM|USR1)$/ ) {
        $pm->start( sub {

            my $seed = Crypt::Random::Seed->new( NonBlocking => 1 );
            srand($seed->random_values(1));

            my $max_reqs_per_child = $self->_calc_minmax_per_child(
                $self->{max_reqs_per_child},
                $self->{min_reqs_per_child}
            );

            my $proc_req_count = 0;
            $self->{term_received} = 0;
            local $SIG{TERM} = sub {
                $self->{term_received}++;
            };
            local $SIG{PIPE} = 'IGNORE';

            PROC_LOOP: while ( $proc_req_count < $max_reqs_per_child ) {
                if ( $self->{term_received} ) {
                    $self->{child_exit}->($self, $app);
                    exit 0;
                }
                if ( my ($conn, $buf, $env) = accept_psgi(
                     fileno($self->{listen_sock}), $self->{timeout}, $self->{_listen_sock_is_tcp},
                     $self->{host} || 0, $self->{port} || 0 )
                ) {
                    my $guard = guard { close_client($conn) };
                    ++$proc_req_count;

                    my $res = $bad_response;
                    my $chunked = do { no warnings; lc delete $env->{HTTP_TRANSFER_ENCODING} eq 'chunked' };
                    if ( my $cl = $env->{CONTENT_LENGTH} ) {
                        my $buffer = Stream::Buffered->new($cl);

                        while ($cl > 0) {
                            my $chunk = "";
                            if (length $buf) {
                                $chunk = $buf;
                                $buf = '';
                            } else {
                                read_timeout(
                                    $conn, \$chunk, $cl, 0, $self->{timeout})
                                    or next PROC_LOOP;
                            }
                            $buffer->print($chunk);
                            $cl -= length $chunk;
                        }
                        $env->{'psgi.input'} = $buffer->rewind;
                    } elsif ( $chunked ) {
                        my $buffer = Stream::Buffered->new($cl);
                        my $chunk_buffer = '';
                        my $length;

                        DECHUNK: while(1) {
                            my $chunk = "";
                            if ( length $buf ) {
                                $chunk = $buf;
                                $buf = '';
                            }
                            else {
                                read_timeout(
                                    $conn, \$chunk, 16384, 0, $self->{timeout})
                                    or next PROC_LOOP;
                            }

                            $chunk_buffer .= $chunk;
                            while ( $chunk_buffer =~ s/^(([0-9a-fA-F]+).*\015\012)// ) {
                                my $trailer   = $1;
                                my $chunk_len = hex $2;
                                if ($chunk_len == 0) {
                                    last DECHUNK;
                                } elsif (length $chunk_buffer < $chunk_len + 2) {
                                    $chunk_buffer = $trailer . $chunk_buffer;
                                    last;
                                }
                                $buffer->print(substr $chunk_buffer, 0, $chunk_len, '');
                                $chunk_buffer =~ s/^\015\012//;
                                $length += $chunk_len;
                            }
                        }
                        $env->{CONTENT_LENGTH} = $length;
                        $env->{'psgi.input'} = $buffer->rewind;
                    } else {
                        $env->{'psgi.input'} = $null_io;
                    }
                    $env->{'psgix.informational'} = sub {
                        my ($status,$headers) = @_;
                        write_informational_response($conn, $self->{timeout}, $status, $headers);
                    };
                    $res = Plack::Util::run_app $app, $env;
                    my $use_chunked = $env->{"SERVER_PROTOCOL"} eq 'HTTP/1.1' ? 1 : 0;
                    if (ref $res eq 'ARRAY') {
                        $self->_handle_response($res, $conn, $use_chunked);
                    } elsif (ref $res eq 'CODE') {
                        $res->(sub {
                            $self->_handle_response($_[0], $conn, $use_chunked);
                        });
                    } else {
                        die "Bad response $res";
                    }
                    if ($env->{'psgix.harakiri.commit'}) {
                        $self->{child_exit}->($self, $app);
                        exit 0;
                    }
                }
            }
        });
    }
    while ($pm->wait_all_children(1)) {
        $pm->signal_all_children('TERM');
    }
}

sub _calc_minmax_per_child {
    my $self = shift;
    my ($max,$min) = @_;

    if ( defined $min ) {
        return $max - int(($max - $min + 1) * rand);
    }

    return $max;
}

sub _handle_response {
    my($self, $res, $conn, $use_chunked) = @_;
    my $status_code = $res->[0];
    my $headers = $res->[1];
    my $body = $res->[2];

    if (defined $body && ref $body eq 'ARRAY' ) {
        write_psgi_response($conn, $self->{timeout}, $status_code, $headers , $body, $use_chunked);
        return;
    }

    write_psgi_response_header($conn, $self->{timeout}, $status_code, $headers, [], $use_chunked) or return;

    if (defined $body) {
        my $failed;
        Plack::Util::foreach(
            $body,
            sub {
                return if $failed;
                my $ret;
                if ( $use_chunked ) {
                    $ret = write_chunk($conn, $_[0], 0, $self->{timeout});
                }
                else {
                    $ret = write_all($conn, $_[0], 0, $self->{timeout});
                }
                $failed = 1 if ! defined $ret;
            },
        );
        write_all($conn, "0\015\012\015\012", 0, $self->{timeout}) if $use_chunked;
    } else {
        return Plack::Util::inline_object
            write => sub {
                if ( $use_chunked ) {
                    write_chunk($conn, $_[0], 0, $self->{timeout});
                }
                else {
                    write_all($conn, $_[0], 0, $self->{timeout});
                }
            },
            close => sub {
                write_all($conn, "0\015\012\015\012", 0, $self->{timeout}) if $use_chunked;
            };
    }
}

1;
