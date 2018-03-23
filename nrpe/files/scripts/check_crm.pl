#!/usr/bin/perl
#
# check_crm_v0_7
#
# Copyright © 2013 Philip Garner, Sysnix Consultants Limited
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# Authors: Phil Garner - phil@sysnix.com & Peter Mottram - peter@sysnix.com
#
# v0.1 09/01/2011
# v0.2 11/01/2011
# v0.3 22/08/2011 - bug fix and changes suggested by Vadym Chepkov
# v0.4 23/08/2011 - update for spelling and anchor regex capture (Vadym Chepkov)
# v0.5 29/09/2011 - Add standby warn/crit suggested by Sönke Martens & removal
#                   of 'our' to 'my' to completely avoid problems with ePN
# v0.6 14/03/2013 - Change from \w+ to \S+ in stopped check to cope with
#                   Servers that have non word charachters in.  Suggested by
#                   Igal Baevsky.
# v0.7 01/09/2013 - In testing as still not fully tested.  Adds optional 
#		    constraints check (Boris Wesslowski). Adds fail count 
#		    threshold ( Zoran Bosnjak & Marko Hrastovec )
#
# NOTES: Requires Perl 5.8 or higher & the Perl Module Nagios::Plugin
#        Nagios user will need sudo acces - suggest adding line below to
#        sudoers
#	     nagios  ALL=(ALL) NOPASSWD: /usr/sbin/crm_mon -1 -r -f
#
#		if you want to check for location constraints (-c) also add
#	     nagios  ALL=(ALL) NOPASSWD: /usr/sbin/crm configure show
#
#	     In sudoers if requiretty is on (off state is default)
#	     you will also need to add the line below
#	     Defaults:nagios !requiretty
#

use warnings;
use strict;
use Nagios::Plugin;

# Lines below may need changing if crm_mon or sudo installed in a
# different location.

my $sudo               = '/usr/bin/sudo';
my $crm_mon            = '/usr/sbin/crm_mon -1 -r -f';
my $crm_configure_show = '/usr/sbin/crm configure show';

my $np = Nagios::Plugin->new(
    shortname => 'check_crm',
    version   => '0.7',
    usage     => "Usage: %s <ARGS>\n\t\t--help for help\n",
);

$np->add_arg(
    spec => 'warning|w',
    help =>
'If failed Nodes, stopped Resources detected or Standby Nodes sends Warning instead of Critical (default) as long as there are no other errors and there is Quorum',
    required => 0,
);

$np->add_arg(
    spec     => 'standbyignore|s',
    help     => 'Ignore any node(s) in standby, by default sends Critical',
    required => 0,
);

$np->add_arg(
    spec => 'constraint|constraints|c',
    help => 'Also check configuration for location constraints (caused by migrations) and warn if there are any.  Requires additional privileges see notes',
    required => 0,
);

$np->add_arg(
    spec     => 'failcount|failcounts|f=i',
    help     => 'resource fail count to start warning on [default = 1].',
    required => 0,
    default  => 1,
);

$np->getopts;
my $ConstraintsFlag = $np->opts->constraint;

my @standby;

# Check for -w option set warn if this is case instead of crit
my $warn_or_crit = 'CRITICAL';
$warn_or_crit = 'WARNING' if $np->opts->warning;

my $fh;

open( $fh, "$sudo $crm_mon |" )
  or $np->nagios_exit( CRITICAL, "Running $sudo $crm_mon has failed" );

foreach my $line (<$fh>) {

    if ( $line =~ m/Connection to cluster failed\:(.*)/i ) {

        # Check Cluster connected
        $np->nagios_exit( CRITICAL, "Connection to cluster FAILED: $1" );
    }
    elsif ( $line =~ m/Current DC:/ ) {

        # Check for Quorum
        if ( $line =~ m/partition with quorum$/ ) {

            # Assume cluster is OK - we only add warn/crit after here

            $np->add_message( OK, "Cluster OK" );
        }
        else {
            $np->add_message( CRITICAL, "No Quorum" );
        }
    }
    elsif ( $line =~ m/^offline:\s*\[\s*(\S.*?)\s*\]/i ) {

        # Count offline nodes
        my @offline = split( /\s+/, $1 );
        my $numoffline = scalar @offline;
        $np->add_message( $warn_or_crit, ": $numoffline Nodes Offline" );
    }
    elsif ( $line =~ m/^node\s+(\S.*):\s*standby/i ) {

        # Check for standby nodes (suggested by Sönke Martens)
        # See later in code for message created from this
        push @standby, $1;
    }

    elsif ( $line =~ m/\s*(\S+)\s+\(\S+\)\:\s+Stopped/ ) {

        # Check Resources Stopped
        $np->add_message( $warn_or_crit, ": $1 Stopped" );
    }
    elsif ( $line =~ m/\s*stopped\:\s*\[(.*)\]/i ) {

        # Check Master/Slave stopped
        $np->add_message( $warn_or_crit, ": $1 Stopped" );
    }
    elsif ( $line =~ m/^Failed actions\:/ ) {

        # Check Failed Actions
        $np->add_message( CRITICAL,
            ": FAILED actions detected or not cleaned up" );
    }
    elsif ( $line =~ m/\s*(\S+?)\s+ \(.*\)\:\s+\w+\s+\w+\s+\(unmanaged\)\s+/i )
    {

        # Check Unmanaged
        $np->add_message( CRITICAL, ": $1 unmanaged FAILED" );
    }
    elsif ( $line =~ m/\s*(\S+?)\s+ \(.*\)\:\s+not installed/i ) {

        # Check for errors
        $np->add_message( CRITICAL, ": $1 not installed" );
    }
    elsif ( $line =~ m/\s*(\S+?):.*fail-count=(\d+)/i ) {
        if ( $2 >= $np->opts->failcount ) {

            # Check for resource Fail count (suggested by Vadym Chepkov)
            $np->add_message( WARNING, ": $1 failure detected, fail-count=$2" );
        }
    }
}

# If found any Nodes in standby & no -s option used send warn/crit
if ( scalar @standby > 0 && !$np->opts->standbyignore ) {
    $np->add_message( $warn_or_crit,
        ": " . join( ', ', @standby ) . " in Standby" );
}

close($fh) or $np->nagios_exit( CRITICAL, "Running $crm_mon FAILED" );

# if -c flag set check configuration for constraints
if ($ConstraintsFlag) {

    open( $fh, "$sudo $crm_configure_show|" )
      or $np->nagios_exit( CRITICAL,
        "Running $sudo $crm_configure_show has failed" );

    foreach my $line (<$fh>) {
        if ( $line =~ m/location cli-(prefer|standby)-\S+\s+(\S+)/ ) {
            $np->add_message( WARNING,
                ": $2 blocking location constraint detected" );
        }
    }
    close($fh)
      or $np->nagios_exit( CRITICAL, "Running $crm_configure_show FAILED" );
}

$np->nagios_exit( $np->check_messages() );

