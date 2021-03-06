package Promise::XS;

use strict;
use warnings;

=encoding utf-8

=head1 NAME

Promise::XS - Fast promises in Perl

=head1 SYNOPSIS

    use Promise::XS ();

    my $deferred = Promise::XS::deferred();

    # Do one of these once you have the result of your operation:
    $deferred->resolve( 'foo', 'bar' );
    $deferred->reject( 'oh', 'no!' );

    # Give this to your caller:
    my $promise = $deferred->promise();

The following aggregator functions are exposed:

    # Resolves with a list of arrayrefs, one per promise.
    # Rejects with the results from the first rejected promise.
    my $all_p = Promise::XS::all( $promise1, $promise2, .. );

    # Resolves/rejects with the results from the first
    # resolved or rejected promise.
    my $race_p = Promise::XS::race( $promise3, $promise4, .. );

For compatibility with preexisting libraries, C<all()> may also be called
as C<collect()>.

=head1 STATUS

The basics of this interface—C<deferred()>

=head1 DESCRIPTION

This module exposes a Promise interface with its major parts
implemented in XS for speed. It is a fork and refactor of
L<AnyEvent::XSPromises>. That module’s interface, a “bare-bones”
subset of that from L<Promises>, is retained.

=head1 EVENT LOOPS

This library, by default, uses no event loop. This is a perfectly usable
configuration; however, it’ll be a bit different from how promises usually
work in evented contexts (e.g., JavaScript) because callbacks will execute
immediately rather than at the end of the event loop as the Promises/A+
specification requires.

To achieve full Promises/A+ compliance it’s necessary to integrate with
an event loop interface. This library supports three such interfaces:

=over

=item * L<AnyEvent>:

    Promise::XS::use_event('AnyEvent');

=item * L<IO::Async> - note the need for an L<IO::Async::Loop> instance
as argument:

    Promise::XS::use_event('IO::Async', $loop_object);

=item * L<Mojo::IOLoop>:

    Promise::XS::use_event('Mojo::IOLoop');

=back

Note that all three of the above are event loop B<interfaces>. They
aren’t event loops themselves, but abstractions over various event loops.
See each one’s documentation for details about supported event loops.

B<REMINDER:> There’s no reason why promises I<need> an event loop; it
just satisfies the Promises/A+ convention.

=head1 TODO

=over

=item * C<all()> and C<race()> should be implemented in XS,
as should C<resolved()> and C<rejected()>.

=back

=head1 SEE ALSO

Besides L<AnyEvent::XSPromises> and L<Promises>, you may like L<Promise::ES6>,
which mimics ECMAScript’s C<Promise> class as much as possible. It can even
(experimentally) use this module as a backend, so it’ll be
I<almost>—but not quite—as fast as using this module directly.

=cut

use Exporter 'import';
our @EXPORT_OK= qw/all collect deferred resolved rejected/;

use Promise::XS::Loader ();
use Promise::XS::Deferred ();

our $DETECT_MEMORY_LEAKS;

use constant DEFERRAL_CR => {
    AnyEvent => \&Promise::XS::Deferred::set_deferral_AnyEvent,
    'IO::Async' => \&Promise::XS::Deferred::set_deferral_IOAsync,
    'Mojo::IOLoop' => \&Promise::XS::Deferred::set_deferral_Mojo,
};

# convenience
*deferred = *Promise::XS::Deferred::create;

sub use_event {
    my ($name, @args) = @_;

    if (my $cr = DEFERRAL_CR()->{$name}) {
        $cr->(@args);
    }
    else {
        die( __PACKAGE__ . ": unknown event engine: $name" );
    }
}

sub resolved {
    return deferred()->resolve(@_)->promise();
}

sub rejected {
    return deferred()->reject(@_)->promise();
}

#----------------------------------------------------------------------
# Aggregator functions

# Lifted from AnyEvent::XSPromises
sub all {
    my $remaining= 0+@_;
    my @values;
    my $failed= 0;
    my $then_what= deferred();
    my $pending= 1;
    my $i= 0;
    for my $p (@_) {
        my $i= $i++;
        $p->then(sub {
            $values[$i]= \@_;
            if ((--$remaining) == 0) {
                $pending= 0;
                $then_what->resolve(@values);
            }
        }, sub {
            if (!$failed++) {
                $pending= 0;
                $then_what->reject(@_);
            }
        });
    }
    if (!$remaining && $pending) {
        $then_what->resolve(@values);
    }
    return $then_what->promise;
}

# Compatibility with other promise interfaces.
*collect = *all;

# Lifted from Promise::ES6
sub race {

    # Perl 5.16 and earlier leak memory when the callbacks are handled
    # inside the closure here.
    my $deferred = deferred();

    my $is_done;

    for my $given_promise (@_) {
        last if $is_done;

        $given_promise->then(
            sub {
                return if $is_done;
                $is_done = 1;

                $deferred->resolve(@_);

                # Proactively eliminate references:
                undef $deferred;
            },
            sub {
                return if $is_done;
                $is_done = 1;

                $deferred->reject(@_);

                # Proactively eliminate references:
                undef $deferred;
            }
        );
    }

    return $deferred->promise();
}

1;
