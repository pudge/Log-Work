package Log::Work;
{
  $Log::Work::VERSION = '0.02.03';
}
# ABSTRACT:  Break tasks into labeld units of work that are trackable across hosts and helper systems.

use strict;
use warnings;

use Log::Work::ProvenanceId;
use Log::Work::Util qw< _set_handler first_external_package >;

use Time::HiRes qw( time );
use Scalar::Util qw(weaken blessed reftype );
use Carp qw( croak );

use Exporter qw( import );
our @EXPORT_OK = qw(
        WORK

        RESULT_NORMAL
        RESULT_INVALID
        RESULT_EXCEPTION
        RESULT_FAILURE

        record_value
        add_metric
        set_result
        has_result

        new_child_id
        new_remote_id
        current_unit
);

our @EXPORT = qw(
        WORK
        RESULT_NORMAL
        RESULT_INVALID
        RESULT_EXCEPTION
        RESULT_FAILURE
);

our %EXPORT_TAGS = (
        simple    => [qw( WORK
                          RESULT_NORMAL
                          RESULT_INVALID
                          RESULT_EXCEPTION
                          RESULT_FAILURE
                     )],
        new_ids   => [qw( new_child_id
                          new_remote_id
                     )],
        metadata  => [qw( add_metric
                          record_value
                          set_result
                          has_result
                     )],
        standard  => [qw(
                          WORK
                          RESULT_NORMAL
                          RESULT_INVALID
                          RESULT_EXCEPTION
                          RESULT_FAILURE
                          new_child_id
                          new_remote_id
                          add_metric
                          record_value
                          set_result
                          has_result
            )],
);

# Keep track of the current unit of work.
# This is intentionally a package variable as it will be
# managed via dynamic scoping using local().
our $CURRENT_UNIT = undef;

our $DEFAULT_ON_ERROR  = sub { warn "@_" };
our $DEFAULT_ON_FINISH = sub { return shift };

our $ON_ERROR  = $DEFAULT_ON_ERROR;
our $ON_FINISH = $DEFAULT_ON_FINISH;

{    # Attribute Setup

    my @ATTRIBUTES = qw(
            parent      children
            id          counter
            name        namespace
            start_time  end_time
            finished    duration
            result      result_code
            metrics     values
            return_values
            return_exception
        );
    my %ATTRIBUTES = map { $_ => undef } @ATTRIBUTES;

    sub new {
        my $class = shift;
        my %arg   = @_;

        my $self = bless {}, $class;
        $self->{$_} = $arg{$_} for keys %ATTRIBUTES;

        return $self;
    }
};


# Define RESULT_FAILURE, RESULT_EXCEPTION, RESULT_INVALID, and RESULT_NORMAL
BEGIN {
    my %result = (
        INVALID    => 'reason_invalid',
        EXCEPTION  => 'exception',
        FAILURE    => 'reason_failure',
        NORMAL     => 'reason_normal',
    );

    for my $result_type ( keys %result ) {

        my $sub = sub {
            my $self = eval { $_[0]->isa('Log::Work'); } ? shift : $CURRENT_UNIT;
            unless( eval { $self->isa( 'Log::Work' ); } ) {
                my $msg =  "Unable to set $result_type on an invalid object.";
                $ON_ERROR->( $msg );
                croak $msg;
            }
            $self->{result} = $result_type;

            if( @_ ) {
                my $value = shift;
                my $name = $result{$result_type};
                $self->record_value( $name, $value );
            }
            ();
        };
        no strict 'refs';
        *{"RESULT_$result_type"} = $sub;

    }
}


sub on_error {
    shift; # Remove invocant
    _set_handler( \$ON_ERROR, $DEFAULT_ON_ERROR, @_ );
    return;
}

sub on_finish {
    shift; # Remove invocant
    _set_handler( \$ON_FINISH, $DEFAULT_ON_FINISH, @_ );
    return;
}

sub has_default_on_finish {
    return $ON_FINISH eq $DEFAULT_ON_FINISH;
}

sub has_default_on_error {
    return $ON_ERROR eq $DEFAULT_ON_ERROR;
}


# Special attribute accessors
sub _children {
    my $self = shift;

    $self->{children}  = {}
        unless $self->{children};

    return $self->{children};
}

sub _metrics {
    my $self = shift;

    $self->{metrics} = {}
        unless $self->{metrics};

    return $self->{metrics};
}

sub _values {
    my $self = shift;

    $self->{values} = {}
        unless $self->{values};

    return $self->{values};
}

sub _add_child {
    my $self = shift;
    my $child = shift;

    my $children = $self->_children;
    my $key = $child->{id};

    $children->{$key} = $child;
    weaken $self->{child}{$key};

    return $self;
}

sub _get_children {
    my $self = shift;

    my $children = $self->_children;

    return grep $_, values %$children;
}

sub get_values {
    my $self  = shift;
    return %{ $self->_values };
}


sub get_metrics {
    my $self  = shift;
    return %{ $self->{metrics} || {} };
}

# ----------------------------------------------------------
#   Low level interface methods
# ----------------------------------------------------------

sub start {
    my $class    = shift;
    my $name     = shift;
    my $pvid_in  = shift;
    my $alt_base = shift;

    # Fill in a provenance id if a good one wasn't provided.
    # Checked via validity test instead of argument count to make it simpler
    # to accept provenance from optional request headers or whatnot.
    my $pvid = $pvid_in;
    if( !Log::Work::ProvenanceId::is_valid_prov_id($pvid) ) {
        $pvid = $CURRENT_UNIT ? $CURRENT_UNIT->new_child_id : Log::Work::ProvenanceId::new_root_id($alt_base);
    }

    my $package = first_external_package();

    my $self = $class->new(
        parent      => $CURRENT_UNIT,
        children    => {},   # Store weak kid refs so that they go away when kids are dead.

        id          => $pvid,
        name        => $name,
        namespace   => $package,

        start_time  => time,
        end_time    => undef,
        result      => undef,
        finished    => undef,

        metrics     => {},
        values      => {},
        counter     => 0,   # First child is 1, next is 2, etc, regardless of internal/external.
    );

    $CURRENT_UNIT->_add_child($self) if $CURRENT_UNIT;

    # Log this down here so that it could show up in the new unit of work
    if( defined($pvid_in) && $pvid_in ne $pvid ) {
        $ON_ERROR->( 'Attempt to use invalid provenance id', $pvid_in, $self );
    }

    return $self;
}



sub step {
    my $self = shift;
    my $code = shift;

    local $CURRENT_UNIT = $self;

    if (!defined wantarray) {
        $code->();
        return;
    }
    if (wantarray) {
        my @return_values = $code->();
        $self->{return_values} = \@return_values;
        return @return_values;
    }
    else {
        my $return_value = $code->();
        $self->{return_values} = [ $return_value ];
        return $return_value;
    }
}

sub finish {
    my $self = shift;

    unless( eval { $self->isa('Log::Work') } ) {
        $ON_ERROR->( "Invalid Work specified for finish", $self );
        $self = Log::Work->new(
            parent      => 'INVALID',
            children    => {}, 
            id          => 'INVALID',
            name        => 'INVALID',
            package     => 'INVALID',

            start_time  => time,
            end_time    => undef,
            result      => undef,
            finished    => undef,

            metrics     => {},
            values      => {},
        );
    }

    if( $self->{finished} ) {
        my $msg = 'Attempt to finish previously finished Work';
        $ON_ERROR->( $msg, $self );
        $self->RESULT_INVALID($msg);
    }

    my @children = $self->_get_children;
    $_->finish for grep !$_->{finished}, grep defined, @children;

    $self->{end_time} = time;
    $self->{duration} = $self->{end_time} - $self->{start_time};

    unless ( $self->has_result ) {
        $self->RESULT_INVALID('No result specified');
    }

    $self->{finished} = 1;

    return $ON_FINISH->( $self );
}

sub current_unit { $CURRENT_UNIT }

# ----------------------------------------------------------
#   High level interface methods
# ----------------------------------------------------------

sub WORK (&$;$$) {
    my $code = shift;
    my $u = __PACKAGE__->start(@_);

    local $@;
    eval {
       # Forcing array context
       my @foo = $u->step( $code );
       1;
    }
    or do {
        my $e = $@;
        $u->RESULT_EXCEPTION()
            unless $u->has_result;
        $u->record_value( exception => $e );
        $u->{return_exception} = $e;
    };

    return $u->finish;
}

# ----------------------------------------------------------
#  Task methods
# ----------------------------------------------------------

sub new_child_id {
    my $self = @_ ? shift : $CURRENT_UNIT;

    unless( eval { $self->isa( 'Log::Work' ); } ) {
        $ON_ERROR->( 'Error generating child ID: Invalid parent unit of work specified.' );
        return Log::Work::ProvenanceId::new_root_id();
    }

    return $self->_new_id( '' );
}

sub new_remote_id {
    my $self = @_ ? shift : $CURRENT_UNIT;

    unless( eval { $self->isa( 'Log::Work' ); } ) {
        my $msg = 'Error creating remote ID: Invalid parent unit of work specified.';
        $ON_ERROR->( $msg );
        croak $msg;
    }

    return $self->_new_id( 'r' );
}

sub _new_id {
    my $self       = shift;
    my $remotifier = shift; # '' or 'r'

    $self->{counter}++;

    my $separator = $self->{id} =~ /:$/ ? '' : ',';

    my $id = sprintf "%s%s%s%s", $self->{id}, $separator, $self->{counter}, $remotifier;

    return $id;
}


sub record_value {
    my $self = blessed $_[0] ? shift : $CURRENT_UNIT;
    my @kvp  = @_;

    # Check for even number of arguments.
    $ON_ERROR->( 'record_values() requires a list of name/value pairs for its arguments' )
        unless @kvp % 2 == 0;

    while( @kvp ) {
        my $name  = shift @kvp;
        my $value = shift @kvp;

        my $values = $self->_values;

        if( exists $values->{$name} ) {
            $ON_ERROR->( "ERROR - That value is already set!", $name, $values->{$name} );
        }

        $values->{$name} = $value;
    }

    return $self;
}


sub add_metric {
    my $self   = blessed $_[0] ? shift : $CURRENT_UNIT;
    my $name   = shift;
    my $amount = shift;
    my $unit   = shift;

    # Get the metric hash ref and be sure that it is stored in the object.
    my $metrics = $self->_metrics;

    my $metric = $metrics->{$name};
    $metric = $metrics->{$name} = {}
        unless $metric;

    # Make sure units haven't changed.
    if( defined $metric->{unit}
            and
        defined $unit
            and
        $unit ne $metric->{unit}
    ) {
        $ON_ERROR->( "ERROR - That metric has a different unit" );
        return $self;
    }

    # Finally adjust the metric
    $metric->{count}++;
    $metric->{total} += $amount;
    $metric->{unit}   = $unit 
        if defined $unit;

    return $self;
}


# Purposely allow non-specified values here.
sub set_result {
    my $self = blessed $_[0] ? shift : $CURRENT_UNIT;

    $self->{result} = shift;

    return $self;
}

sub has_result {
    my $self = blessed $_[0] ? shift : $CURRENT_UNIT;

    return defined $self->{result};
}

1;

__END__

=head1 NAME

Log::Work

=head1 VERSION

version 0.02.03

=head1 SYNOPSIS

=head1 DESCRIPTION

=head2 Simplified Interface


=head3 WORK

The core of the simplified interface.  This function is the heart of unit of work logging.

Arguments:

    Code to execute
    Unit of Work Name
    Provenance Id (optional)

Return:

    Result of the on_finish() handler.

Examples:

    Log::Work->on_finish( sub { serialize_work_for_my_logger( @_ ) } );

    $application->log( WORK { eat_cheese() } 'Cheese Consumption' );

    my $request = $application->get_dairy_request();
    $application->log( WORK { eat_more_cheese() } 'Further Cheese Consumption', $request->provenance_id );

What's happening here?

C<WORK> handles a lot of book-keeping so you don't have to.

When called, it:

=over 4

=item 1.

Creates a unit of work object complete with a correct provenance id.

=item 1.

Calls the code it was passed in.

=item 1.

Handles all the book-keeping needed to:

=over 4

=item *

Track execution time

=item *

Enforce result classification

=item *

Propagate return values

=item *

Propagate exceptions

=item *

Transform the Log::Work object into something your logging system can handle.

=back

=back

=head3 current_unit

Inside a unit of work, we always know what unit we are in.  You can access the current Log::Work object at any time by calling C<current_unit>
either as an imported funtion or as a Log::Work class method.

Examples:

    WORK {
        my $u = current_unit();

        grubby_sub();

        WORK {

            grubby_sub();

        } 'Inner grub';

    } 'Outer grub';

    sub grubby_sub {
        my $u = Log::Work->current_unit();
    }

In this example the Work object accessed by C<grubby_sub()> depends on the call. In the outer block, the 'Outer grub' unit is found.  In the inner block, we access 'Inner grub'.

=head3 RESULT_NORMAL
=head3 RESULT_FAILURE
=head3 RESULT_EXCEPTION
=head3 RESULT_INVALID


=head2 Manual Interface

    start

    on_error
    on_finish
    step
    set_result
    finish
    _new_id

    new_child_id
    new_remote_id

    has_result
    record_value
    add_metric
    current_unit
    has_default_on_finish
    has_default_on_error
    get_values
    get_metrics

=head1 EXPORTS

Log::Work flies in the face of common sense and pollutes your namespace with exported functions.  It does this with the goal of simplicity.

=head2 Exportable functions

    WORK

    RESULT_EXCEPTION  RESULT_FAILURE
    RESULT_INVALID    RESULT_NORMAL

    has_result        set_result
    record_value      add_metric

    current_unit

    new_child_id      new_remote_id

=head2 Export tags

=over 4

=item :standard

All of :simple :new_ids :metadata

=item :simple

    WORK

    RESULT_NORMAL
    RESULT_FAILURE
    RESULT_INVALID
    RESULT_EXCEPTION

=item :new_ids

    new_child_id
    new_remote_id

=item :metadata

    add_metric
    record_value
    has_result
    set_result

=back

=head1 SEE ALSO

=head1 CREDITS
