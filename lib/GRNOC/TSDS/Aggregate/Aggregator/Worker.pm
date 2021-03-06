package GRNOC::TSDS::Aggregate::Aggregator::Worker;

use Moo;

use GRNOC::WebService::Client;
use GRNOC::TSDS::Aggregate::Aggregator::Message;
use GRNOC::TSDS::Aggregate::Histogram;

use Net::AMQP::RabbitMQ;
use JSON::XS;
use Math::Round qw( nlowmult nhimult );
use List::MoreUtils qw( natatime );
use Try::Tiny;

use Data::Dumper;

### constants ###

use constant QUEUE_PREFETCH_COUNT => 20;
use constant QUEUE_FETCH_TIMEOUT => 10 * 1000;
use constant RECONNECT_TIMEOUT => 10;
use constant PENDING_QUEUE_CHANNEL => 1;
use constant FINISHED_QUEUE_CHANNEL => 2;
use constant SERVICE_CACHE_FILE => '/etc/grnoc/name-service-cacher/name-service.xml';
use constant COOKIES_FILE => '/var/lib/grnoc/tsds/aggregate/cookies.dat';

### required attributes ###

has config => ( is => 'ro',
                required => 1 );

has logger => ( is => 'ro',
                required => 1 );

### internal attributes ###

has is_running => ( is => 'rwp',
                    default => 0 );

has rabbit => ( is => 'rwp' );

has json => ( is => 'rwp' );

has websvc => ( is => 'rwp' );

### public methods ###

sub start {

    my ( $self ) = @_;

    $self->logger->debug( "Starting." );

    # flag that we're running
    $self->_set_is_running( 1 );

    # change our process name
    $0 = "tsds_aggregator [worker]";

    # setup signal handlers
    $SIG{'TERM'} = sub {

        $self->logger->info( "Received SIG TERM." );
        $self->stop();
    };

    $SIG{'HUP'} = sub {

        $self->logger->info( "Received SIG HUP." );
    };

    # create JSON object
    my $json = JSON::XS->new();

    $self->_set_json( $json );

    # create websvc object
    my $websvc = GRNOC::WebService::Client->new( uid => $self->config->get( '/config/tsds/username' ),
						 passwd => $self->config->get( '/config/tsds/password' ),
						 realm => $self->config->get( '/config/tsds/realm' ),
						 service_cache_file => SERVICE_CACHE_FILE,
						 cookieJar => COOKIES_FILE,
						 usePost => 1 );

    $websvc->set_service_identifier( 'urn:publicid:IDN+grnoc.iu.edu:' . $self->config->get( '/config/tsds/cloud' ) . ':TSDS:1:Query' );

    $self->_set_websvc( $websvc );

    # connect to rabbit queues
    $self->_rabbit_connect();

    # continually consume messages from rabbit queue, making sure we have to acknowledge them
    $self->logger->debug( 'Starting RabbitMQ consume loop.' );

    return $self->_consume_loop();
}

sub stop {

    my ( $self ) = @_;

    $self->logger->debug( 'Stopping.' );

    # this will cause the consume loop to exit
    $self->_set_is_running( 0 );
}

### private methods ###

sub _consume_loop {

    my ( $self ) = @_;

    while ( 1 ) {

        # have we been told to stop?
        if ( !$self->is_running ) {

            $self->logger->debug( 'Exiting consume loop.' );
            return 0;
        }

        # receive the next rabbit message
        my $rabbit_message;

        try {

            $rabbit_message = $self->rabbit->recv( QUEUE_FETCH_TIMEOUT );
        }

        catch {

            $self->logger->error( "Error receiving rabbit message: $_" );

            # reconnect to rabbit since we had a failure
            $self->_rabbit_connect();
        };

        # didn't get a message?
        if ( !$rabbit_message ) {

            $self->logger->debug( 'No message received.' );

            # re-enter loop to retrieve the next message
            next;
        }

        # try to JSON decode the messages
        my $messages;

        try {

            $messages = $self->json->decode( $rabbit_message->{'body'} );
        }

        catch {

            $self->logger->error( "Unable to JSON decode message: $_" );
        };

        if ( !$messages ) {

            try {

                # reject the message and do NOT requeue it since its malformed JSON
                $self->rabbit->reject( PENDING_QUEUE_CHANNEL, $rabbit_message->{'delivery_tag'}, 0 );
            }

            catch {

                $self->logger->error( "Unable to reject rabbit message: $_" );

                # reconnect to rabbit since we had a failure
                $self->_rabbit_connect();
            };
        }

        # retrieve the next message from rabbit if we couldn't decode this one
        next if ( !$messages );

        # make sure its an array (ref) of messages
        if ( ref( $messages ) ne 'ARRAY' ) {

            $self->logger->error( "Message body must be an array." );

            try {

                # reject the message and do NOT requeue since its not properly formed
                $self->rabbit->reject( PENDING_QUEUE_CHANNEL, $rabbit_message->{'delivery_tag'}, 0 );
            }

            catch {

                $self->logger->error( "Unable to reject rabbit message: $_" );

                # reconnect to rabbit since we had a failure
                $self->_rabbit_connect();
            };

            next;
        }

        my $num_messages = @$messages;
        $self->logger->debug( "Processing message containing $num_messages aggregations to perform." );

        my $t1 = time();

        my $success = $self->_consume_messages( $messages );

        my $t2 = time();
        my $delta = $t2 - $t1;

        $self->logger->debug( "Processed $num_messages updates in $delta seconds." );

        # didn't successfully consume the messages, so reject but requeue the entire message to try again
        if ( !$success ) {

            $self->logger->debug( "Rejecting rabbit message, requeueing." );

            try {

                $self->rabbit->reject( 1, $rabbit_message->{'delivery_tag'}, 1 );
            }

            catch {

                $self->logger->error( "Unable to reject rabbit message: $_" );

                # reconnect to rabbit since we had a failure
                $self->_rabbit_connect();
            };
        }

        # successfully consumed message, acknowledge it to rabbit
        else {

            $self->logger->debug( "Acknowledging successful message." );

            try {

                $self->rabbit->ack( 1, $rabbit_message->{'delivery_tag'} );
            }

            catch {

                $self->logger->error( "Unable to acknowledge rabbit message: $_" );

                # reconnect to rabbit since we had a failure
                $self->_rabbit_connect();
            };
        }
    }
}

sub _consume_messages {

    my ( $self, $messages ) = @_;

    # gather all messages to process
    my $aggregates_to_process = [];

    # handle every TSDS message that came within the rabbit message
    foreach my $message ( @$messages ) {

        # make sure message is an object/hash (ref)
        if ( ref( $message ) ne 'HASH' ) {

            $self->logger->error( "Messages must be an object/hash of data, skipping." );
            next;
        }

        my $type = $message->{'type'};
        my $interval_from = $message->{'interval_from'};
        my $interval_to = $message->{'interval_to'};
        my $start = $message->{'start'};
        my $end = $message->{'end'};
        my $meta = $message->{'meta'};
	my $values = $message->{'values'};
	my $required_meta = $message->{'required_meta'};

	my $aggregate_message;

	try {

	    $aggregate_message = GRNOC::TSDS::Aggregate::Aggregator::Message->new( type => $type,
										   interval_from => $interval_from,
										   interval_to => $interval_to,
										   start => $start,
										   end => $end,
										   meta => $meta,
										   values => $values,
										   required_meta => $required_meta );
	}

	catch {

	    $self->logger->error( $_ );
	};

	# include this to our list of messages to process if it was valid
	push( @$aggregates_to_process, $aggregate_message ) if $aggregate_message;
    }

    # aggregate all of the data across all messages
    my $success = 1;

    try {

        $self->_aggregate_messages( $aggregates_to_process ) if ( @$aggregates_to_process > 0 );
    }

    catch {

        $self->logger->error( "Error aggregating messages: $_" );
        $success = 0;
    };

    return $success;
}

sub _aggregate_messages {

    my ( $self, $messages ) = @_;

    my $finished_messages = [];

    foreach my $message ( @$messages ) {

	my $type = $message->type;
	my $from = $message->interval_from;
	my $to = $message->interval_to;
	my $start = $message->start;
	my $end = $message->end;
	my $meta = $message->meta;
	my $values = $message->values;
	my $required_meta = $message->required_meta;

	# align to aggregation window we're getting data for
	$start = nlowmult( $to, $start );
	$end = nhimult( $to, $end );

	my $min_max_mappings = $self->_get_min_max_mappings( required_meta => $required_meta,
							     meta => $meta );

	my $hist_mappings = $self->_get_histogram_mappings( $values );

	# craft the query needed to fetch the data from the necessary interval
	my $from_clause = "from $type";
	my $values_clause = $self->_get_values_clause( from => $from, values => $values, required_meta => $required_meta );
	my $between_clause = $self->_get_between_clause( start => $start, end => $end, to => $to );
	my $where_clause = $self->_get_where_clause( $meta );
	my $by_clause = $self->_get_by_clause( $required_meta );
	my $query = "$values_clause $between_clause $by_clause $from_clause $where_clause";

	# issue the query to the webservice to retrieve the data we need to aggregate
	my $results = $self->websvc->query( query => $query );

	# handle any errors attempting to query the webservice
	if ( !$results ) {

	    die( "Error querying TSDS web service: " . $self->websvc->get_error() );
	}

	if ( $results->{'error'} ) {

	    die( "Error retrieving data from TSDS: " . $results->{'error_text'} );
	}

	$results = $results->{'results'};

	my $buckets = {};
	my $meta_info = {};

	foreach my $result ( @$results ) {

	    my @value_types = keys( %$result );
	    my $meta_data = {};
	    my @meta_keys;

	    # the required fields are not one of the possible value types
	    foreach my $required ( @$required_meta ) {

		@value_types = grep { $_ ne $required } @value_types;
		$meta_data->{$required} = $result->{$required};
		push( @meta_keys, $result->{$required} );
	    }

	    my $key = join( '__', @meta_keys );
	    $meta_info->{$key} = $meta_data;

	    foreach my $value_type ( @value_types ) {

		my $entries = $result->{$value_type};

		foreach my $entry ( @$entries ) {

		    my ( $timestamp, $value ) = @$entry;

		    my $bucket = nlowmult( $to, $timestamp );

		    $buckets->{$key}{$bucket}{$value_type} = [] if ( !defined( $buckets->{$key}{$bucket}{$value_type} ) );

		    push( @{$buckets->{$key}{$bucket}{$value_type}}, $entry );
		}
	    }
	}

	# handle every measurement that was bucketed
	my @keys = keys( %$buckets );

	foreach my $key ( @keys ) {

	    # grab meta data hash to pass for this measurement
	    my $meta_data = $meta_info->{$key};

	    # handle every bucketed timestamp for this measurement
	    my @timestamps = keys( %{$buckets->{$key}} );

	    foreach my $time ( @timestamps ) {

		# all the data during this bucket to aggregate for this measurement
		my $data = $buckets->{$key}{$time};

		my $aggregated = $self->_aggregate( data => $data,
						    required_meta => $required_meta,
						    hist_mappings => $hist_mappings,
						    hist_min_max_mappings => $min_max_mappings,
						    key => $key );
		
		$aggregated->{'type'} = "$type.aggregate";
		$aggregated->{'time'} = $time;
		$aggregated->{'interval'} = $to;
		$aggregated->{'meta'} = $meta_data;

		push( @$finished_messages, $aggregated );
	    }
	}
    }

    my $num = @$finished_messages;
    warn "NUM: $num";

    # send a max of 100 messages at a time to rabbit
    my $it = natatime( 100, @$finished_messages );

    my $queue = $self->config->get( '/config/rabbit/finished-queue' );

    while ( my @finished_messages = $it->() ) {

	$self->rabbit->publish( FINISHED_QUEUE_CHANNEL, $queue, $self->json->encode( \@finished_messages ), {'exchange' => ''} );
    }
}

sub _aggregate {

    my ( $self, %args ) = @_;

    my $data = $args{'data'};

    my $required_meta = $args{'required_meta'};
    my $hist_mappings = $args{'hist_mappings'};
    my $hist_min_max_mappings = $args{'hist_min_max_mappings'};
    my $key = $args{'key'};

    my $result = {};

    my @value_types = keys( %$data );

    foreach my $value_type ( @value_types ) {

	my $min;
	my $max;
	my $sum;
	my $count;
	my $avg;
	my $hist;

	# figure out the smallest/largest possible min/max to use for the histogram
	my $hist_min = $hist_min_max_mappings->{$key}{'min'};
	my $hist_max = $hist_min_max_mappings->{$key}{'max'};

	my $hist_res = $hist_mappings->{$value_type}{'hist_res'};
	my $hist_min_width = $hist_mappings->{$value_type}{'hist_min_width'};

        # handle every value in this type
	my $entries = $data->{$value_type};

	foreach my $entry ( @$entries ) {

	    my ( $timestamp, $value ) = @$entry;

            # initialize total count, sum, min, max if needed
	    $count = 0 if ( !defined( $count ) );
	    $sum = 0 if ( !defined( $sum ) );

	    $min = $value if ( !defined( $min ) );
	    $max = $value if ( !defined( $max ) );

            # determine new sum for our average calculation
	    $sum += $value if ( defined $value );

	    $count++ if ( defined $value );

            # determine if there is a new min/max
	    $min = $value if ( defined( $value ) && $value < $min );
	    $max = $value if ( defined( $value ) && $value > $max );
	}

        # we have the min, max, and sum, but we also need the mean/avg
	$avg = $sum / $count if $count;

        # generate our percentile histogram between min => max
	if ( defined( $min ) && defined( $max ) && $min != $max ) {

	    if ( $hist_res && $hist_min_width ) {

                $hist = GRNOC::TSDS::Aggregate::Histogram->new( hist_min => $hist_min,
                                                                hist_max => $hist_max,
                                                                data_min => $min,
                                                                data_max => $max,
                                                                min_width => $hist_min_width,
                                                                resolution => $hist_res );
	    }

	    if ( defined( $hist ) ) {

		my @values;

                # add every value into our histogram
		foreach my $entry ( @$entries ) {

		    my ( $timestamp, $value ) = @$entry;

		    push( @values, $value );
		}

		$hist->add_values( \@values );

		$hist = {'total' => $hist->total,
                         'bin_size' => $hist->bin_size,
                         'num_bins' => $hist->num_bins,
                         'min' => $hist->hist_min,
                         'max' => $hist->hist_max,
			 'bins' => $hist->bins};
	    }
	}

        # all done handling the aggregation of this data type
	$result->{'values'}{$value_type} = {'min' => $min,
					    'max' => $max,
					    'avg' => $avg,
					    'hist' => $hist};
    }

    return $result;
}

sub _get_histogram_mappings {

    my ( $self, $values ) = @_;

    my $mappings = {};

    foreach my $value ( @$values ) {

	my $name = $value->{'name'};
	my $hist_res = $value->{'hist_res'};
	my $hist_min_width = $value->{'hist_min_width'};

	$mappings->{$name}{'hist_res'} = $hist_res;
	$mappings->{$name}{'hist_min_width'} = $hist_min_width;
    }

    return $mappings;
}

sub _get_min_max_mappings {

    my ( $self, %args ) = @_;

    my $required_meta = $args{'required_meta'};
    my $meta = $args{'meta'};

    my $mappings = {};

    foreach my $entry ( @$meta ) {

	my $fields = $entry->{'fields'};
	my $values = $entry->{'values'};

	my @key_fields;

	foreach my $required_meta ( @$required_meta ) {
	    
	    push( @key_fields, $fields->{$required_meta} );
	}

	foreach my $value ( @$values ) {

	    my $value_name = $value->{'name'};	    
	    my $min = $value->{'min'};
	    my $max = $value->{'max'};

	    my $key = join( '__', ( @key_fields, $value_name ) );

	    $mappings->{$key}{'min'} = $min;
	    $mappings->{$key}{'max'} = $max;
	}
    }

    return $mappings;
}

sub _get_values_clause {

    my ( $self, %args ) = @_;

    my $from = $args{'from'};
    my $values = $args{'values'};
    my $required_meta = $args{'required_meta'};

    # pull out all value names
    my @value_names = map { $_->{'name'} } @$values;

    # convert each value name to proper aggregation based upon the interval we are fetching the data from
    my @values = map { "aggregate(values.$_, $from, average) as $_" } @value_names;

    # comma separate each
    my $values_clause = "get " . join( ', ', @$required_meta, @values );

    return $values_clause;
}

sub _get_between_clause {

    my ( $self, %args ) = @_;

    my $start = $args{'start'};
    my $end = $args{'end'};
    my $to = $args{'to'};

    # make sure we fetch all data within the from interval
    $start = nlowmult( $to, $start );
    $end = nhimult( $to, $end );

    return "between ($start, $end)";
}

sub _get_by_clause {

    my ( $self, $required_meta ) = @_;

    my $by_clause = "by " . join( ',', @$required_meta );

    return $by_clause;
}

sub _get_where_clause {

    my ( $self, $meta ) = @_;

    my @or_clauses;

    foreach my $entry ( @$meta ) {

	my @clause;

	my $fields = $entry->{'fields'};

	while ( my ( $key, $value ) = each( %$fields ) ) {

	    push( @clause, "$key = \"$value\"" );
	}

	my $clause = '( ' . join( ' and ', @clause ) . ' )';

	push( @or_clauses, $clause );
    }

    my $where_clause = "where " . join( ' or ', @or_clauses );

    return $where_clause;
}

sub _rabbit_connect {

    my ( $self ) = @_;

    my $rabbit_host = $self->config->get( '/config/rabbit/host' );
    my $rabbit_port = $self->config->get( '/config/rabbit/port' );
    my $rabbit_pending_queue = $self->config->get( '/config/rabbit/pending-queue' );
    my $rabbit_finished_queue = $self->config->get( '/config/rabbit/finished-queue' );

    while ( 1 ) {

        $self->logger->info( "Connecting to RabbitMQ $rabbit_host:$rabbit_port." );

        my $connected = 0;

        try {

            my $rabbit = Net::AMQP::RabbitMQ->new();

            $rabbit->connect( $rabbit_host, {'port' => $rabbit_port} );

	    # open channel to the pending queue we'll read from
            $rabbit->channel_open( PENDING_QUEUE_CHANNEL );
            $rabbit->queue_declare( PENDING_QUEUE_CHANNEL, $rabbit_pending_queue, {'auto_delete' => 0} );
            $rabbit->basic_qos( PENDING_QUEUE_CHANNEL, { prefetch_count => QUEUE_PREFETCH_COUNT } );
            $rabbit->consume( PENDING_QUEUE_CHANNEL, $rabbit_pending_queue, {'no_ack' => 0} );

	    # open channel to the finished queue we'll send to
            $rabbit->channel_open( FINISHED_QUEUE_CHANNEL );
            $rabbit->queue_declare( FINISHED_QUEUE_CHANNEL, $rabbit_finished_queue, {'auto_delete' => 0} );

            $self->_set_rabbit( $rabbit );

            $connected = 1;
        }

        catch {

            $self->logger->error( "Error connecting to RabbitMQ: $_" );
        };

        last if $connected;

        $self->logger->info( "Reconnecting after " . RECONNECT_TIMEOUT . " seconds..." );
        sleep( RECONNECT_TIMEOUT );
    }
}

1;
