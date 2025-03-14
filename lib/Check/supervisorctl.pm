package Check::supervisorctl;

use 5.006;
use strict;
use warnings;
use File::Slurp qw(read_dir);

=head1 NAME

Check::supervisorctl - Check the status of supervisorctl to see if it is okay.

=head1 VERSION

Version 0.0.1

=cut

our $VERSION = '0.0.1';

=head1 SYNOPSIS

    use Check::supervisorctl;

    my $check_supervisorctl = Check::supervisorctl->new();
    ...

=head1 SUBROUTINES/METHODS

=head2 new

=cut

sub new {
	my ( $blank, %opts ) = @_;

	my $self = {
		status_mapping => {
			stopped  => 2,
			starting => 0,
			running  => 0,
			backoff  => 2,
			stopping => 2,
			exited   => 2,
			fatal    => 2,
			unknown  => 2,
		},
		val_to_string => {
			0 => 'OK',
			1 => 'WARNING',
			2 => 'ALERT',
			3 => 'UNKNOWN'
		},
		not_running_val            => 2,
		config_missing_val         => 2,
		config_dir_missing_val     => 3,
		config_dir_nonreadable_val => 3,
		config_check               => 0,
		ignore                     => {},
		config_ignore              => {},
		config_dir                 => '/usr/local/etc/supervisord/conf.d',
	};
	bless $self;

	if ( $^O eq 'linux' ) {
		$self->{config_dir} = '/etc/supervisord/conf.d';
	}

	# read in any specified status mappings and
	if ( defined( $opts{status_mapping} ) ) {
		if ( ref( $opts{status_mapping} ) ne 'HASH' ) {
			die( '$opts{status_mapping} not a ref type of HASH but "' . ref( $opts{status_mapping} ) . '"' );
		}
		foreach my $status ( keys( %{ $opts{status_mapping} } ) ) {
			my $lc_status = lc($status);
			if ( ref( $opts{status_mapping}{$status} ) ne '' ) {
				die(      '$opts{status_mapping}{'
						. $status
						. '} is not of ref type "" but "'
						. ref( $opts{status_mapping}{$status} )
						. '"' );
			}
			if ( !defined( $self->{status_mapping}{$lc_status} ) ) {
				die(      "'"
						. $status
						. "' is not a known status type... expected stopped, starting, running backoff, stopping, exited, fatal, unknown"
				);
			}
			if ( $opts{status_mapping}{$status} !~ /^[0123]$/ ) {
				die(      '$opts{status_mapping}{'
						. $status
						. '} is not 0, 1, 2, or 3, but "'
						. $opts{status_mapping}{$status}
						. '"' );
			}
			$self->{status_mapping}{$lc_status} = $opts{status_mapping}{$status};
		} ## end foreach my $status ( keys( %{ $opts{status_mapping...}}))
	} ## end if ( defined( $opts{status_mapping} ) )

	if ( defined( $opts{config_check} ) ) {
		if ( ref( $opts{config_check} ) ne '' ) {
			die( '$opts{config_check} is not of ref type "" but "' . ref( $opts{config_check} ) . '"' );
		}
		$self->{config_check} = $opts{config_check};
		if ( defined( $opts{config_dir} ) ) {
			if ( ref( $opts{config_dir} ) ne '' ) {
				die( '$opts{config_dir} is not of ref type "" but "' . ref( $opts{config_dir} ) . '"' );
			}
			$self->{config_dir} = $opts{config_dir};
		}
	} ## end if ( defined( $opts{config_check} ) )

	return $self;
} ## end sub new

=head2 run

=cut

sub run {
	my $self = $_[0];

	my $to_return = {
		configs             => [],
		config_not_running  => [],
		config_missing      => [],
		config_check        => $self->{config_check},
		config_dir          => $self->{config_dir},
		config_ignored      => [],
		config_ignore       => sort( %{ $self->{config_ignore} } ),
		exit                => 0,
		status              => {},
		total               => 0,
		config_totals       => 0,
		ignored             => [],
		ignore              => sort( keys( %{ $self->{ignore} } ) ),
		config_dir_missing  => 0,
		config_dir_readable => 1,
		status_count        => {
			stopped  => 0,
			starting => 0,
			running  => 0,
			backoff  => 0,
			stopping => 0,
			exited   => 0,
			fatal    => 0,
			unknown  => 0,
		},
		status_list => {
			stopped  => [],
			starting => [],
			running  => [],
			backoff  => [],
			stopping => [],
			exited   => [],
			fatal    => [],
			unknown  => [],
		},
		results => []
	};

	my $output       = `supervisorctl status 2> /dev/null`;
	my @output_split = split( /\n/, $output );

	foreach my $line (@output_split) {
		my ( $name, $status ) = /^(\S+)\s(\S+)\s*/;
		if ( defined( $self->{ignore}{$name} ) ) {
			push( @{ $to_return->{ignored} }, $name );
		} else {
			if ( defined($status) && defined($name) ) {
				if ( $self->{ignore}{$name} ) {
					push( @{ $to_return->{ignored} }, $name );
					push( @{ $to_return->{results} }, 'IGNORED - ' . $name . ', ' . $status );
				} else {
					$status = lc($status);
					if ( defined( $self->{status_mapping}{$status} ) ) {
						if ( $to_return->{exit} < $self->{status_mapping}{$status} ) {
							$to_return->{exit} = $self->{status_mapping}{$status};
						}
						$to_return->{status}{$name} = $status;
						push( @{ $to_return->{status_list}{$status} }, $name );
						push(
							@{ $to_return->{results} },
							$self->{val_to_string}{ $self->{status_mapping}{$status} } . ' - '
								. $name . ', '
								. $status
						);
						$to_return->{status_count}{$status}++;
					} ## end if ( defined( $self->{status_mapping}{$status...}))
				} ## end else [ if ( $self->{ignore}{$name} ) ]
			} ## end if ( defined($status) && defined($name) )
		} ## end else [ if ( defined( $self->{ignore}{$name} ) ) ]
	} ## end foreach my $line (@output_split)

	if ( $self->{config_check} ) {
		if ( -d $self->{config_dir} ) {
			my @dir_entries;
			eval { @dir_entries = read_dir( $self->{config_dir} ); };
			if ($@) {
				$to_return->{config_dir_readable} = 0;
				if ( $to_return->{exit} < $self->{config_dir_nonreadable_val} ) {
					$to_return->{exit} = $self->{config_dir_nonreadable_val};
				}
			}
			if ( $to_return->{config_dir_readable} ) {
				my %configs;
				foreach my $entry ( sort(@dir_entries) ) {
					if ( $entry =~ /\.conf$/ && -f $self->{config_dir} . '/' . $entry ) {
						$entry = s/\.conf$//;
						if ( $self->{ config_ignore { $entry } } ) {
							push( @{ $to_return->{config_ignored} }, $entry );
							push( @{ $to_return->{results} },        'IGNORED - config ' . $entry );
						} else {
							push( @{ $to_return->{configs} }, $entry );
							$configs{$entry} = 1;
							if ( !defined( $to_return->{status}{$entry} ) ) {
								push( @{ $to_return->{config_not_running} }, $entry );
								push(
									@{ $to_return->{results} },
									$self->{val_to_string}{ $self->{not_running_val} }
										. ' - non-running config '
										. $entry
								);
								if ( $to_return->{exit} < $self->{not_running_val} ) {
									$to_return->{exit} = $self->{not_running_val};
								}
							} else {
								push( @{ $to_return->{results} }, 'OK - config ' . $entry );
							}
						} ## end else [ if ( $self->{ config_ignore { $entry } } )]

					} ## end if ( $entry =~ /\.conf$/ && -f $self->{config_dir...})
				} ## end foreach my $entry ( sort(@dir_entries) )
				foreach my $running ( keys( %{ $to_return->{status} } ) ) {
					if ( $configs{$running} ) {
						push( @{ $to_return->{config_missing} }, $running );
						push(
							@{ $to_return->{results} },
							$self->{val_to_string}{ $self->{not_running_val} } . ' - missing config ' . $running
						);
					} else {
						push( @{ $to_return->{results} }, 'OK - config present for ' . $running );
					}
				} ## end foreach my $running ( keys( %{ $to_return->{status...}}))

			} ## end if ( $to_return->{config_dir_readable} )
		} else {
			$to_return->{config_dir_missing} = 1;
			if ( $to_return->{exit} < $self->{config_dir_missing_val} ) {
				$to_return->{exit} = $self->{config_dir_missing_val};
			}
		}
	} ## end if ( $self->{config_check} )

} ## end sub run

=head1 AUTHOR
Zane C. Bowers-Hadley, C<< <vvelox at vvelox.net> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-check-supervisorctl at rt.cpan.org>, or through
the web interface at L<https://rt.cpan.org/NoAuth/ReportBug.html?Queue=Check-supervisorctl>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Check::supervisorctl


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<https://rt.cpan.org/NoAuth/Bugs.html?Dist=Check-supervisorctl>

=item * CPAN Ratings

L<https://cpanratings.perl.org/d/Check-supervisorctl>

=item * Search CPAN

L<https://metacpan.org/release/Check-supervisorctl>

=back


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2025 by Zane C. Bowers-Hadley.

This is free software, licensed under:

  The GNU General Public License, Version 3, June 2007


=cut

1;    # End of Check::supervisorctl
