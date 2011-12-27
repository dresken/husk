#!/usr/bin/perl -w

# Copyright (C) 2010-2011 Phillip Smith
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

package main;

use warnings;
use strict;
#use 5.010_001;	# Need Perl version 5.10 for Coalesce operator (//)
use Config::Simple;		# To parse husk.conf
use Config::IniFiles;	# To parse here documents in hostgroups.conf
use Getopt::Long;

my $VERSION = '%VERSION%';

# Configuration Defaults
my %conf_defaults;
$conf_defaults{conf_dir} 		= '/etc/husk';
$conf_defaults{iptables}		= `which iptables 2>/dev/null`;
$conf_defaults{ip6tables}		= `which ip6tables 2>/dev/null`;
$conf_defaults{udc_prefix}		= 'tgt_';
$conf_defaults{ipv4}			= 1;
$conf_defaults{ipv6}			= 0;
$conf_defaults{ignore_autoconf}	= 0;
$conf_defaults{old_state_track}	= 0;

# runtime vars
my ($conf_file, $conf_dir, $udc_prefix, $kw);
my ($iptables, $ip6tables);	# Paths to binaries
my ($do_ipv4, $do_ipv6);	# Enable/Disable specific IP Versions
my $ignore_autoconf;		# Ignore autoconf traffic before antispoof logging?
my $old_state_track;		# Use 'state' module instead of 'conntrack'
my $disable_ipv6_comments;	# Early versions of ip6tables didn't support the 'comment' module
my $curr_chain;				# Name of current chain to append rules to
my $current_rules_file;		# The filename of the rules currently being read (needs to be globally scoped to use in multiple subs)
my $line_cnt = 0;			# Counter for line number (needs to be globally scoped to use in multiple subs)
my $xzone_prefix = 'x';		# Prefix for Cross-zone chain names

# Arrays and Hashes
my %interface;		# Interfaces Name to eth Mappings (eg, NET => ppp0)
my %addr_group;		# Hostgroups from hostgroups.conf
my @ipv4_rules;		# IPv4 Rules in iptables syntax to be output
my @ipv6_rules;		# IPv6 Rules in iptables syntax to be output
my %xzone_calls;	# Hash of cross-zone traffic rulesets (eg, x_LAN_NET)
my %udc_list;		# Names of User-Defined Chains
my %user_var;		# User Defined Variables

# somewhere to store info for the 'common' rules we have to include in the output
my %spoof_protection;	# Hash of Arrays to store valid networks per interface (see &compile_standard)
my @bogon_protection;	# Array of interfaces to provide bogon protection on
my @portscan_protection;# Array of interfaces to provide portscan protection on
my @xmas_protection;	# Array of interfaces to provide xmas packet protection on
my @syn_protection;		# Array of interfaces to provide NEW NO SYN protection on

# compile some standard regex patterns
# any variables starting with "qr_" are precompiled regexes
my $qr_mac_address	= qr/(([A-F0-9]{2}[:.-]?){6})/io;
my $qr_hostname		= qr/(([A-Z0-9]|[A-Z0-9][A-Z0-9\-]*[A-Z0-9])\.)*([A-Z]|[A-Z][A-Z0-9\-]*[A-Z0-9])/io;
my $qr_ip4_address	= qr/(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)/o;
my $qr_ip4_cidr		= qr/(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(\/([0-9]{1,2}))?/o;
my $qr_ip6_address	= qr/${\&make_ipv6_regex()}/io;
my $qr_ip6_cidr		= qr/${\&make_ipv6_regex()}(\/[0-9]{1,3})?/io;
my $qr_if_names		= qr/((eth|ppp|bond|tun|tap|sit|(xen)?br|vif)(\d+|\+)((\.|:)\d+)?|lo|xen[A-Z]+)/io;
my $qr_int_name		= qr/\w+/o;
my $qr_first_word	= qr/\A(\w+)/o;
my $qr_define_xzone	= qr/\Adefine\s+rules\s+($qr_int_name)\s+to\s+($qr_int_name)\z/io;
my $qr_define_sub	= qr/\Adefine\s+rules\s+(\w+)\b?\z/io;
my $qr_add_chain	= qr/\Adefine\s+rules\s+(INPUT|FORWARD|OUTPUT)\b?\z/io;
my $qr_def_variable	= qr/\Adefine\s+var(iable)?\s+(\w+)\b?\z/io;
my $qr_tgt_builtins	= qr/\A(accept|drop|reject|log)\b/io;
my $qr_tgt_redirect	= qr/\A(redirect|trap)\b/io;
my $qr_tgt_map		= qr/\Amap\b/io;
my $qr_tgt_common	= qr/\Acommon\b/io;
my $qr_tgt_iptables	= qr/\Aiptables\b/io;
my $qr_tgt_ip6tables= qr/\Aip6tables\b/io;
my $qr_tgt_include	= qr/\Ainclude\b(.+)\z/io;
my $qr_end_define	= qr/\Aend\s+define\b?\z/io;
# regex precompilation for keyword matching and extraction
my $qr_kw_ip		= qr/\bip\s+(4|6|both)\b/io;
my $qr_kw_protocol	= qr/\bproto(col)? ([\w]+)\b/io;
my $qr_kw_in_int	= qr/\bin(coming)? ($qr_int_name)\b/io;
my $qr_kw_out_int	= qr/\bout(going)? ($qr_int_name)\b/io;
# Note that ORDER is IMPORTANT in these 2 regexes because an IPv6 *address*
# looks very similar to a hostname (as far as our regexes are concerned) so
# we need to try and match the IPv6 address before trying to make our
# 'hostname' regex pattern otherwise we treat an IPv6 address as a hostname
# IOW: make sure the IPv6 regex is tested before the hostname regex.
my $qr_kw_src_addr	= qr/\bsource address ($qr_ip4_cidr|$qr_ip6_cidr|$qr_hostname)\b/io;
my $qr_kw_dst_addr	= qr/\bdest(ination)? address ($qr_ip4_cidr|$qr_ip6_cidr|$qr_hostname)\b/io;
my $qr_kw_src_host	= qr/\bsource group (\S+)\b/io;
my $qr_kw_dst_host	= qr/\bdest(ination)? group (\S+)\b/io;
my $qr_kw_src_range	= qr/\bsource range ($qr_ip4_address|$qr_ip6_address) to ($qr_ip4_address|$qr_ip6_address)\b/io;
my $qr_kw_dst_range	= qr/\bdest(ination)? range ($qr_ip4_address|$qr_ip6_address) to ($qr_ip4_address|$qr_ip6_address)\b/io;
my $qr_port_pattern	= qr/(\d|\w|-)+/io;
my $qr_kw_sport		= qr/\bsource\s+port\s+(($qr_port_pattern:?)+)\b/io;
my $qr_kw_dport		= qr/\b(dest(ination)?)?\s*port (($qr_port_pattern:?)+)\b/io;
my $qr_kw_multisport= qr/\bsource\s+ports\s+(($qr_port_pattern,?)+)\b/io;
my $qr_kw_multidport= qr/\b(dest(ination)?)?\s*ports\s+(($qr_port_pattern,?)+)\b/io;
my $qr_quoted_string= qr/"([^"\\]+|\\.)*"/o;
my $qr_kw_prefix	= qr/\bprefix $qr_quoted_string/io;
my $qr_kw_limit		= qr/\blimit (\S+)\s*(burst (\d+))?\b/io;
my $qr_kw_type		= qr/\btype (\S+)\b/io;
my $qr_time24		= qr/([0-1]?\d|2[0-3]):([0-5]\d)(:([0-5]\d))?/o;
my $qr_kw_start		= qr/\bstart ($qr_time24)\b/io;
my $qr_kw_finish	= qr/\bfinish ($qr_time24)\b/io;
my $qr_kw_days		= qr/\bdays? ((((Mon?|Tue?|Wed?|Thu?|Fri?|Sat?|Sun?)\w*),?)+)\b/io;
my $qr_kw_every		= qr/\bevery (\d+)\b/io;
my $qr_kw_offset	= qr/\boffset (\d+)\b/io;
my $qr_kw_state		= qr/\bstate (NEW|ESTABLISHED|RELATED|INVALID|UNTRACKED)\b/io;
my $qr_kw_mac_addr	= qr/\bmac ($qr_mac_address)\b/io;
my $qr_kw_noop		= qr/\b(all)\b/io;
my $qr_call_any		= qr/_ANY(_|\b)/o;
my $qr_call_me		= qr/_ME(_|\b)/o;
my $qr_variable		= qr/\%(\w+)/io;

# Constants
my %IPV4_BOGON_SOURCES = (
	'10.0.0.0/8'		=> 'Private (RFC-1918)',
	'172.16.0.0/12'		=> 'Private (RFC-1918)',
	'192.168.0.0/16'	=> 'Private (RFC-1918)',
	'169.254.0.0/16'	=> 'Link Local (RFC-3927)',
	'127.0.0.0/8'		=> 'Loopback (RFC-1122)',
	'255.255.255.255'	=> 'Broadcast (RFC-919)',
	'192.0.2.0/24'		=> 'TEST-NET - IANA (RFC-1166)',
	'198.51.100.0/24'	=> 'TEST-NET-2 - IANA',
	'203.0.113.0/24'	=> 'TEST-NET-3 - APNIC (RFC-5737)',
	'192.0.0.0/24'		=> 'IETF Protocol Assignment (RFC-5736)',
	'198.18.0.0/15'		=> 'Benchmark Testing (RFC-2544)',
	'240.0.0.0/4'		=> 'Class E Reserved (RFC-1112)',
);
# Most of these IPv6 bogons are sourced from:
# http://6session.wordpress.com/2009/04/08/ipv6-martian-and-bogon-filters/
my %IPV6_BOGON_SOURCES = (
	'3fff:ffff::/32'	=> 'EXAMPLENET-WF',
	'2001:0DB8::/32'	=> 'EXAMPLENET-WF',
	'fec0::/10'			=> 'Site Local Addresses (RFC-3879)',
	'::/96'				=> 'Deprecated (RFC-4291)',
	'::/128'			=> 'Unspecified address',
	'::1/128'			=> 'Loopback',
	'::ffff:0.0.0.0/96'	=> 'IPv4-mapped addresses',
	'0000::/8'			=> 'Embedded IPv4 addresses',
	'0200::/7'			=> 'RFC-4548/RFC-4048',
	'2001:db8::/32'		=> 'IANA Reserved',
	'2002:0000::/24'	=> '6to4; IPv4 default',
	'2002:0a00::/24'	=> '6to4; IPv4 RFC-1918',
	'2002:7f00::/24'	=> '6to4; IPv4 loopback',
	'2002:ac10::/28'	=> '6to4; IPv4 RFC-1918',
	'2002:c0a8::/32'	=> '6to4; IPv4 RFC-1918',
	'2002:e000::/20'	=> '6to4; IPv4 multicast',
	'2002:ff00::/24'	=> '6to4',
	'3ffe::/16'			=> 'Former 6bone',
	'fc00::/7'			=> 'RFC-4193',
);

# Most of these rules gathered from "gotroot.com":
# 	http://www.gotroot.com/Linux+Firewall+Rules
# Included with permission granted via the "GOT ROOT LICENSE":
# 	http://www.gotroot.com/Got+Root+License
my %PORTSCAN_RULES;
$PORTSCAN_RULES{'-p tcp --tcp-flags ALL FIN,URG,PSH'}	= 'PORTSCAN: NMAP FIN/URG/PSH';
$PORTSCAN_RULES{'-p tcp --tcp-flags SYN,RST SYN,RST'}	= 'PORTSCAN: SYN/RST';
$PORTSCAN_RULES{'-p tcp --tcp-flags SYN,FIN SYN,FIN'}	= 'PORTSCAN: SYN/FIN';
$PORTSCAN_RULES{'-p tcp --tcp-flags ALL FIN'}			= 'PORTSCAN: NMAP FIN Stealth';
$PORTSCAN_RULES{'-p tcp --tcp-flags ALL ALL'}			= 'PORTSCAN: ALL/ALL';
$PORTSCAN_RULES{'-p tcp --tcp-flags ALL NONE'}			= 'PORTSCAN: NMAP Null Scan';

# An array of reserved words that can't be used as target names
my @RESERVED_WORDS = (qw(
	accept		drop		log			redirect	trap
	map			common		iptables	ip6tables	include
));

###############################################################################
#### MAIN CODE
###############################################################################

# Handle command line args
&handle_cmd_args;

# read config files
$conf_file = coalesce($conf_file, '/etc/husk/husk.conf');
&read_config_file(fname=>$conf_file);
&load_addrgroups(fname=>sprintf('%s/addr_groups.conf', $conf_dir));
&load_interfaces(fname=>sprintf('%s/interfaces.conf', $conf_dir));

# Start Processing
{
	&init;
	my $rules_fname = sprintf('%s/rules.conf', $conf_dir);
	&read_rules_file($rules_fname);
	&close_rules;

	# Cleanup and Output
	&generate_output;
}

exit 0;

###############################################################################
#### SUBROUTINES
###############################################################################

# this is the "meat" of processing the rules file. it loops through each line
# in the file and determines the appropriate subroutine to translate the rule
# into the corresponding iptables or ip6tables command.
# usgae: &read_rules_file($fname)
# fname => filename of the rules file to process
sub read_rules_file {
	my ($fname) = @_;

	# Validate what was passed
	&bomb((caller(0))[3] . ' called without passing filename of rules') unless $fname;

	my $closing_tgt;		# Where to JUMP when we close the current chain
	my $in_def_variable;	# Boolean if we're "inside" a "define var" block

	# make sure the file exists first
	&bomb(sprintf('Rules file does not exist: %s', $fname))
		unless (-f $fname);

	local(*FILE);
	open FILE, "<$fname" or &bomb("Failed to read $fname");
	my @lines = <FILE>;
	close(FILE);
	$current_rules_file = $fname;
	$line_cnt = 0;

	# Find and parse all our subroutine chains first
	ParseLines:
	foreach my $line (@lines) {
		chomp($line);
		$line_cnt++;

		# ignore blank and comment only lines
		$line = &cleanup_line($line);
		next ParseLines unless $line;

		if ($line =~ m/$qr_define_xzone/) {
			# Start of a 'define rules ZONE to ZONE'
			my ($i_name, $o_name) = (uc($1), uc($2));

			# make sure we're not still inside an earlier define rules
			&bomb(sprintf("'%s' starts before '%s' block has ended!", $line, $curr_chain))
					if ($curr_chain);

			$curr_chain = &new_call_chain(line=>$line, in=>$i_name, out=>$o_name);

			# Work out what to do when this chain ends:
			#	- RETURN for 'ANY' rules
			#	- DROP for all others
			if ($i_name eq 'ANY' or $o_name eq 'ANY') {
				$closing_tgt = 'RETURN';
			} else {
				$closing_tgt = 'DROP';
			}
		}
		elsif ($line =~ m/$qr_add_chain/) {
			# handle blocks adding to INPUT, OUTPUT and/or FORWARD
			# the regex for this pattern explicitly defines INPUT, OUTPUT and FORWARD as
			# the only valid options, so we don't need to test we have a 'valid' chain
			# since the regex ensures we only match if we do.
			my $chain_name = uc($1);

			# make sure we're not still inside an earlier block
			&bomb(sprintf("'%s' starts before '%s' block has ended!", $line, $curr_chain))
					if ($curr_chain);

			$curr_chain = $chain_name;
		}
		elsif ($line =~ m/$qr_define_sub/) {
			# Start of a user-defined chain
			my $udc_name = $1;

			# make sure we're not still inside an earlier block
			&bomb(sprintf("'%s' starts before '%s' block has ended!", $line, $curr_chain))
					if ($curr_chain);

			# make sure the user isn't trying to use a reserved word
			&bomb(sprintf('Target "%s" is named the same as a reserved word. This is invalid', $udc_name))
				if (grep(m/$udc_name/i, @RESERVED_WORDS));

			$curr_chain = &new_udc_chain(line=>$line, udc_name=>$udc_name);
		}
		elsif ($line =~ m/$qr_tgt_builtins/) {
			# call rule - jump to built-in
			&bomb("Call rule found outside define block on line $line_cnt:\n\t$line")
				unless ($curr_chain);
			&compile_call(chain=>$curr_chain, line=>$line);
		}
		elsif ($line =~ m/$qr_def_variable/) {
			my $var_name = $2;
			&bomb("Variable already defined: $var_name")
				if ($user_var{$var_name});
			# Loop through all the next lines until we find 'end define'
			VariableLines:
			for (my $v = $line_cnt; 1; $v++) {
				my $val = $lines[$v];
				chomp($val);

				$val = &cleanup_line($val);

				next VariableLines unless $val;

				last VariableLines if ($val =~ m/$qr_end_define/);

				push(@{$user_var{$var_name}}, $val);
			}
			$in_def_variable = 1;
		}
		elsif ($line =~ m/$qr_tgt_map/) {
			&compile_nat($line);
		}
		elsif ($line =~ m/$qr_tgt_redirect/) {
			# redirect/trap rule
			&compile_interception($line);
		}
		elsif ($line =~ m/$qr_tgt_common/) {
			# 'common' rule
			&compile_common($line);
		}
		# note that we use s// on these comparisons to strip the leading string so
		# the rest of the rule is ready to pass to &ipt4 or &ipt6
		elsif ($line =~ s/$qr_tgt_iptables//) {
			# raw iptables command
			my $raw_rule = &trim($line);

			# are we enabled for this ip version?
			&bomb(sprintf("Found an iptables rule but you've told me not to build ipv4 rules?\n\t%s", $line))
					unless ($do_ipv4);

			$raw_rule =~ s/%CHAIN%/$curr_chain/;
			$raw_rule = sprintf('%s -m comment --comment "husk line %s"', $raw_rule, $line_cnt);
			&ipt4($raw_rule);
		}
		elsif ($line =~ s/$qr_tgt_ip6tables//) {
			# raw ip6tables command
			my $raw_rule = &trim($line);

			# are we enabled for this ip version?
			&bomb(sprintf("Found an ip6tables rule but you've told me not to build ipv6 rules?\n\t%s", $line))
					unless ($do_ipv6);

			$raw_rule =~ s/%CHAIN%/$curr_chain/;
			$raw_rule = sprintf('%s -m comment --comment "husk line %s"', $raw_rule, $line_cnt);
			&ipt6($raw_rule);
		}
		elsif ($line =~ m/$qr_tgt_include/) {
			# include another rules file
			my $include_fname = $1;
			&include_file($include_fname);
		}
		elsif ($line =~ m/$qr_end_define/) {
			# End of a 'define' block; Clear our state and add default rule

			# make sure we are actually in a define rules block
			&bomb(sprintf('Found "%s" but not inside a "define" block?', $line))
					unless ($curr_chain or $in_def_variable);

			&close_chain(chain=>$curr_chain, closing_tgt=>$closing_tgt)
					if ($curr_chain);

			undef($curr_chain);
			undef($in_def_variable);
			$closing_tgt = '';
		}
		else {
			# Ignore if we're inside a variable declaration
			next ParseLines if ($in_def_variable);

			# Extract the first word of the line
			$line =~ m/$qr_first_word/;
			my $first_word = coalesce($1, '');

			# See if this is a UDC to jump to
			my $udc_chain = sprintf('%s%s', $udc_prefix, $first_word);
			if (defined($udc_list{$udc_chain})) {
				# call rule - jump to udc
				&compile_call(chain=>$curr_chain, line=>$line);
			} else {
				&bomb(sprintf(
					'Unknown command on line %s (perhaps a "define rules" block used before it is defined?):%s %s',
					$line_cnt, "\n\t", $line));
			}
		}
	}

	# finished parsing the rules file; clear the line
	# counter so we don't use it by accident
	undef($current_rules_file);
	undef($line_cnt);
}

# create a new call chain (eg x_LAN_NET)
sub new_call_chain {
	my %args	= @_;
	my $line	= $args{'line'};
	my $i_name	= uc($args{'in'});
	my $o_name	= uc($args{'out'});
	my $chain	= sprintf("%s_%s_%s", $xzone_prefix, $i_name, $o_name);

	# Validate what we've found
	&bomb(sprintf('Undefined "in" interface on line %s: %s', $line_cnt, $i_name))
		unless ($interface{$i_name} or $i_name =~ m/\AANY\z/);
	&bomb(sprintf('Undefined "out" interface on line %s: %s', $line_cnt, $o_name))
		unless ($interface{$o_name} or $o_name =~ m/\AANY\z/);

	# Check if we've seen this call before
	&bomb(sprintf("'%s' defined twice (second on line %s)", $line, $line_cnt))
		if (defined($xzone_calls{$chain}));

	# Is this a bridged interface? We need to use the physdev module if it is
	my ($is_bridge_in, $is_bridge_out);
	$is_bridge_in  = &is_bridged(eth=>$interface{$i_name}) if ($interface{$i_name});
	$is_bridge_out = &is_bridged(eth=>$interface{$o_name}) if ($interface{$o_name});

	# Work out if this chain should be called from INPUT, OUTPUT or FORWARD
	my %criteria;

	# Set defaults
	$criteria{'chain'}	= 'FORWARD';
	# We ternary test this assignment because sometimes there won't be a
	# corresponding value in %interface (eg, for ANY)
	$criteria{'in'}		= $interface{$i_name} ? sprintf('-i %s', $interface{$i_name}) : '';
	$criteria{'out'}	= $interface{$o_name} ? sprintf('-o %s', $interface{$o_name}) : '';

	# Override defaults if required
	if ($o_name =~ m/\AME\z/) {
		$criteria{'chain'} = 'INPUT';
		$criteria{'out'} = '';	# -o is invalid in INPUT table
	}
	if ($i_name =~ m/\AME\z/) {
		$criteria{'chain'} = 'OUTPUT';
		$criteria{'in'} = '';	# -i is invalid in OUTPUT table
	}
	# Negate the opposite interface on ANY rules so we don't mess with bounce routing
	if ($o_name =~ m/\AANY\z/) {
		$criteria{'out'} = sprintf('! -o %s', $interface{$i_name});
	}
	if ($i_name =~ m/\AANY\z/) {
		$criteria{'in'} = sprintf('! -i %s', $interface{$o_name});
	}

	# Use the physdev module for rules across bridges
	if ($is_bridge_in) {
		$criteria{'module'}	= '-m physdev';
		$criteria{'in'}		= $interface{$i_name} ? sprintf('--physdev-in %s', $interface{$i_name}) : ''
			unless ($i_name =~ m/\AME\z/);
	}
	if ($is_bridge_out) {
		$criteria{'module'}	= '-m physdev';
		$criteria{'out'}	= $interface{$o_name} ? sprintf('--physdev-out %s', $interface{$o_name}) : ''
			unless ($o_name =~ m/\AME\z/);
	}

	# Build the Rule
	&ipt("-N $chain");
	$xzone_calls{$chain} = collapse_spaces(sprintf(
		'-A %s %s %s %s -m conntrack --ctstate NEW -j %s -m comment --comment "husk line %s"',
		$criteria{'chain'},
		$criteria{'module'} ? $criteria{'module'} : '',
		$criteria{'in'},
		$criteria{'out'},
		$chain,
		$line_cnt ? $line_cnt : 'UNKNOWN',
	));

	# Pass the chain name back
	return $chain;
}

sub new_udc_chain {
	my %args	= @_;
	my $line	= $args{'line'};
	my $udc_name= $args{'udc_name'};
	my $chain	= sprintf("%s%s", $udc_prefix, $udc_name);

	# Check if we've seen this call before
	&bomb(sprintf("'%s' defined twice (second on line %s)", $line, $line_cnt))
		if ($udc_list{$chain});

	# Store the UDC chain name with the line number for later
	$udc_list{$chain} = $line_cnt;

	&ipt("-N $chain");

	# Pass the chain name back
	return $chain;
}

sub close_chain {
	my %args		= @_;
	my $chain		= $args{'chain'};
	my $closing_tgt	= $args{'closing_tgt'};

	if ($closing_tgt and $closing_tgt =~ m/DROP/) {
		# Cross zone chain with DROP to close with.
		&log_and_drop(chain=>$chain);
	} elsif ($closing_tgt) {
		# Cross zone chain with something other than 'DROP' as the closing action.
		&ipt(sprintf('-A %s -j %s', $chain, $closing_tgt));
	} else {
		# This is a UDC; We don't append anything
		;
	}
}

sub close_rules {
	# The tables and chains to put our various "common" protection rules into.
	my $BOGON_TABLE		= 'mangle';
	my $BOGON_CHAIN		= 'cmn_BOGON';
	my $SPOOF_TABLE		= 'mangle';
	my $SPOOF_CHAIN		= 'cmn_SPOOF';
	my $SYN_PROT_TABLE	= 'mangle';
	my $SYN_PROT_CHAIN	= 'cmn_SYN';
	my $XMAS_TABLE		= 'mangle';
	my $XMAS_CHAIN		= 'cmn_XMAS';
	my $PORTSCAN_TABLE	= 'mangle';
	my $PORTSCAN_CHAIN	= 'cmn_PORTSCAN';

	# setup 'common' rules and chains
	if (scalar(@bogon_protection)) {
		# Bogon Protection; per interface
		# Create a chain for bogon protection
		&ipt(sprintf('-t %s -N %s', $BOGON_TABLE, $BOGON_CHAIN));

		# Populate the new chain with rules
		if ($do_ipv4) {
			foreach my $bogon_src (keys %IPV4_BOGON_SOURCES) {
				# LOG and DROP bad sources (bogons)
				&log_and_drop(
					table=>		$BOGON_TABLE,
					chain=>		$BOGON_CHAIN,
					prefix=>	'BOGON',
					ipv4=>		1,
					ipv6=>		0,
					criteria=>	sprintf(
						'-s %s -m comment --comment "%s"',
						$bogon_src,
						$IPV4_BOGON_SOURCES{$bogon_src},
				));
			}
			# End with a default RETURN
			&ipt4(sprintf('-t %s -A %s -j RETURN', $BOGON_TABLE, $BOGON_CHAIN));
		}
		if ($do_ipv6) {
			foreach my $bogon_src (sort(keys %IPV6_BOGON_SOURCES)) {
				# LOG and DROP bad sources (bogons)
				&log_and_drop(
					table=>		$BOGON_TABLE,
					chain=>		$BOGON_CHAIN,
					prefix=>	'BOGON',
					ipv4=>		0,
					ipv6=>		1,
					criteria=>	sprintf(
						'-s %s -m comment --comment "%s"',
						$bogon_src,
						$IPV6_BOGON_SOURCES{$bogon_src},
				));
			}
			# End with a default RETURN
			&ipt6(sprintf('-t %s -A %s -j RETURN', $BOGON_TABLE, $BOGON_CHAIN));
		}

		# Jump the new chain for packets in the user-specified interfaces
		foreach my $int (@bogon_protection) {
			&ipt(sprintf(
				'-t %s -I PREROUTING -i %s -j %s -m comment --comment "bogon protection for %s"',
				$BOGON_TABLE,
				$interface{$int},
				$BOGON_CHAIN,
				$int,
			));
		}
	}

	if (scalar(keys %spoof_protection)) {
		# Antispoof rules; Per interface
		# Create a chain to log and drop
		&ipt(sprintf('-t %s -N %s', $SPOOF_TABLE, $SPOOF_CHAIN));

		foreach my $iface (keys %spoof_protection) {
			# RETURN if the packet is sourced from 0.0.0.0 (eg, DHCP Discover)
			if ( $do_ipv4 ) {
				&ipt4(sprintf('-t %s -A %s -i %s -s 0.0.0.0 -p udp --sport 68 --dport 67 -m comment --comment "DHCP Discover bypasses spoof protection" -j RETURN',
					$SPOOF_TABLE,
					$SPOOF_CHAIN,
					$interface{$iface},
				));
			}

			# RETURN if the packet is ip6 and src from link-local
			push(@{$spoof_protection{$iface}}, 'fe80::/10') if ($do_ipv6);

			# RETURN if the packet is from a known-good source (as specified by user)
			foreach (@{$spoof_protection{$iface}}) {
				my $src = $_;
				if ($src =~ m/$qr_ip4_cidr/) {
					# User has supplied an IPv4 address
					&ipt4(sprintf(
						'-t %s -A %s -i %s -s %s -m comment --comment "valid source for %s" -j RETURN',
						$SPOOF_TABLE,
						$SPOOF_CHAIN,
						$interface{$iface},
						$src,
						$iface));
				}
				elsif ($src =~ m/$qr_ip6_cidr/) {
					# User has supplied an IPv6 address
					&ipt6(sprintf(
						'-t %s -A %s -i %s -s %s -m comment --comment "valid source for %s" -j RETURN',
						$SPOOF_TABLE,
						$SPOOF_CHAIN,
						$interface{$iface},
						$src,
						$iface));
				}
			}

			# Silently DROP if the packet is from autoconfig addr and ignore_autoconf is true
			&ipt4(sprintf('-t %s -A %s -i %s -s 169.254.0.0/16 -m comment --comment "prevent autoconfig addr being logged as spoofed" -j DROP',
				$SPOOF_TABLE,
				$SPOOF_CHAIN,
				$interface{$iface},
			)) if ($ignore_autoconf);

			# LOG, then DROP anything else
			&log_and_drop(
				table=>		$SPOOF_TABLE,
				chain=>		$SPOOF_CHAIN,
				prefix=>	sprintf('SPOOFED in %s', $iface),
				ipv4=>		1,
				ipv6=>		1,
				criteria=>	sprintf(
					'-i %s -m comment --comment "bad source in %s"',
					$interface{$iface},
					$iface,
			));
		}
		# End with a default RETURN
		&ipt(sprintf('-t %s -A %s -j RETURN', $SPOOF_TABLE, $SPOOF_CHAIN));

		# Jump the new chain for packets in the user-specified interfaces
		foreach my $int (keys %spoof_protection) {
			&ipt(sprintf('-t %s -I PREROUTING -i %s -j %s -m comment --comment "spoof protection for %s"',
					$SPOOF_TABLE,
					$interface{$int},
					$SPOOF_CHAIN,
					$int,
				));
		}
	}

	# SYN Protection
	if (scalar(@syn_protection)) {
		# Block NEW packets without SYN set
		&ipt(sprintf('-t %s -N %s', $SYN_PROT_TABLE, $SYN_PROT_CHAIN));
		&log_and_drop(
			table=>		$SYN_PROT_TABLE,
			chain=>		$SYN_PROT_CHAIN,
			prefix=>	'NEW_NO_SYN',
			ipv4=>		1,
			ipv6=>		1,
			criteria=>	'-p tcp ! --syn'
		);
		&ipt(sprintf('-t %s -A %s -j RETURN', $SYN_PROT_TABLE, $SYN_PROT_CHAIN));

		# Jump the new chain for each required interface
		foreach my $int (@syn_protection) {
			&ipt(sprintf(
				'-t %s -I PREROUTING -i %s -p tcp -m conntrack --ctstate NEW -j %s -m comment --comment "syn protection for %s"',
				$SYN_PROT_TABLE,
				$interface{$int},
				$SYN_PROT_CHAIN,
				$int,
			));
		}
	}

	# xmas Protection
	if (scalar(@xmas_protection)) {
		# Block Xmas Packets
		&ipt(sprintf('-t %s -N %s', $XMAS_TABLE, $XMAS_CHAIN));
		&log_and_drop(
			table=>		$XMAS_TABLE,
			chain=>		$XMAS_CHAIN,
			prefix=>	'XMAS_LIGHT',
			ipv4=>		1,
			ipv6=>		1,
			criteria=>	'-p tcp --tcp-flags ALL ALL'
		);
		&log_and_drop(
			table=>		$XMAS_TABLE,
			chain=>		$XMAS_CHAIN,
			prefix=>	'XMAS_DARK',
			ipv4=>		1,
			ipv6=>		1,
			criteria=>	'-p tcp --tcp-flags ALL NONE'
		);
		&ipt(sprintf('-t %s -A %s -j RETURN', $XMAS_TABLE, $XMAS_CHAIN));
		foreach my $int (@xmas_protection) {
			&ipt(sprintf(
				'-t %s -I PREROUTING -i %s -j %s -m comment --comment "xmas protection for %s"',
				$XMAS_TABLE,
				$interface{$int},
				$XMAS_CHAIN,
				$int,
			));
		}
	}

	if (scalar(@portscan_protection)) {
		# Portscan Protection; per interface
		# Create a chain for portscan protection
		&ipt(sprintf('-t %s -N %s', $PORTSCAN_TABLE, $PORTSCAN_CHAIN));

		# Populate the new chain with rules
		foreach my $ps_rule (sort(keys %PORTSCAN_RULES)) {
			# LOG and DROP things that look like portscans
			my $scan_desc = $PORTSCAN_RULES{$ps_rule};
			&log_and_drop(
				table=>		$PORTSCAN_TABLE,
				chain=>		$PORTSCAN_CHAIN,
				prefix=>	$scan_desc,
				ipv4=>		1,
				ipv6=>		1,
				criteria=>	sprintf(
					'%s -m comment --comment "%s"',
					$ps_rule,
					$scan_desc,
			));
		}
		# End with a default RETURN
		&ipt(sprintf('-t %s -A %s -j RETURN', $PORTSCAN_TABLE, $PORTSCAN_CHAIN));

		# Jump the new chain for packets in the user-specified interfaces
		foreach my $int (@portscan_protection) {
			&ipt(sprintf(
				'-t %s -I PREROUTING -i %s -j %s -m comment --comment "portscan protection for %s"',
				$PORTSCAN_TABLE,
				$interface{$int},
				$PORTSCAN_CHAIN,
				$int,
			));
		}
	}

	# Create cross-zone chains for anything not defined by the user.
	$line_cnt = 'autogenerated';
	InterfacesFrom:
	foreach my $int_from (keys %interface) {
		InterfacesTo:
		foreach my $int_to (keys %interface) {
			my $new_chain	= sprintf("%s_%s_%s", $xzone_prefix, $int_from, $int_to);
			next InterfacesTo if ($xzone_calls{$new_chain});	# Don't create already existing chains
			next InterfacesTo if ($int_from =~ m/\AME\z/);		# Don't create OUTPUT chains
			next InterfacesTo if ($int_from eq $int_to);		# Don't create bounce chains

			# Create new chain
			my $curr_chain = &new_call_chain(line=>'none', in=>$int_from, out=>$int_to);
			# Close it off
			&close_chain(chain=>$curr_chain, closing_tgt=>'DROP');
		}
	}
	undef($line_cnt);

	# JUMP to cross-zone traffic chains
	# - Jump anything to/from ME first
	my $any_to_me = sprintf('%s_ANY_ME', $xzone_prefix);
	my $me_to_any = sprintf('%s_ME_ANY', $xzone_prefix);
	if (defined($xzone_calls{$any_to_me})) {
		&ipt($xzone_calls{$any_to_me});
		delete $xzone_calls{$any_to_me};
	}
	if (defined($xzone_calls{$me_to_any})) {
		&ipt($xzone_calls{$me_to_any});
		delete $xzone_calls{$me_to_any};
	}
	# We want to jump any chains to/from the
	# special 'ANY' interface before all
	# other 'call' jumps.
    foreach my $xzone_rule (sort(keys %xzone_calls)) {
		if ($xzone_rule =~ m/$qr_call_any/) {
			&ipt($xzone_calls{$xzone_rule});
			delete $xzone_calls{$xzone_rule};
		}
	}
	# Jump whatever else is left
    foreach my $xzone_rule ( sort(keys %xzone_calls )) {
		&ipt($xzone_calls{$xzone_rule});
	}

	# Create a LOG rule for anything that slips this far. This could
	# happen with packets coming in an interface that has not been
	# defined as a husk zone (ergo has no rules). This traffic will be
	# DROPPED by the chain policy.
	&log_and_drop(chain=>'INPUT',	prefix=>'LATE DROP');
	&log_and_drop(chain=>'FORWARD',	prefix=>'LATE DROP');

	# Set policies
	foreach my $chain (qw(INPUT FORWARD OUTPUT)) {
		&ipt(sprintf('-P %s DROP', $chain));
	}
}

sub print_header {
	print "#\n";
	printf("# husk version %s\n", $VERSION);
	print "# Copyright (C) 2010-2011 Phillip Smith\n";
	print "# This program comes with ABSOLUTELY NO WARRANTY; This is free software, and you are\n";
	print "# welcome to use and redistribute it under the conditions of the GPL license version 2\n";
	print "# See the \"COPYING\" file for further details.\n";
	print "#\n";
}

sub generate_output {
	# Always print license and disclaimer
	&print_header;
	printf("# Ruleset compiled %s\n", &timestamp);
	print "#\n";

	# iptables (IPv4) rules)
	if ($do_ipv4) {
		print "### BEGIN IPv4 RULES ###\n";
		foreach my $r (@ipv4_rules) {
			if ($old_state_track == 1) {
				$r =~ s/-m conntrack --ctstate/-m state --state/g;
			}

			printf("%s %s\n", $iptables, $r);
		}
		print "### END IPv4 RULES ###\n\n";
	}
	# ip6tables (IPv6) rules
	if ($do_ipv6) {
		print "### BEGIN IPv6 RULES ###\n";
		foreach (@ipv6_rules) {
			printf("%s %s\n", $ip6tables, $_);
		}
		print "### END IPv6 RULES ###\n\n";
	}
}

sub log_and_drop {
	my %args = @_;
	my $chain		= $args{'chain'};
	my $table		= $args{'table'} ? sprintf('-t %s', $args{'table'}) : '';
	my $log_prefix	= coalesce($args{'prefix'}, $chain);
	my $ipv4		= coalesce($args{'ipv4'}, 1);	# Assume we want IPv4
	my $ipv6		= coalesce($args{'ipv6'}, 1);	# Assume we want IPv6
	my $criteria	= $args{'criteria'} ? $args{'criteria'} : '';

	# Validate what was passed
	&bomb((caller(0))[3] . ' called without passing $chain') unless $chain;

	if ($ipv4) {
		# LOG the packet
		&ipt4(&collapse_spaces(sprintf('%s -A %s %s -m limit --limit 4/minute --limit-burst 3 -j LOG --log-prefix="[%s] "',
				$table, $chain, $criteria, $log_prefix,
			)));
		# DROP the packet
		&ipt4(&collapse_spaces(sprintf('%s -A %s %s -j DROP',
				$table, $chain, $criteria,
			)));
	}
	if ($ipv6) {
		# LOG the packet
		&ipt6(&collapse_spaces(sprintf('%s -A %s %s -m limit --limit 4/minute --limit-burst 3 -j LOG --log-prefix="[%s] "',
				$table, $chain, $criteria, $log_prefix,
			)));
		# DROP the packet
		&ipt6(&collapse_spaces(sprintf('%s -A %s %s -j DROP',
				$table, $chain, $criteria,
			)));
	}

	return;
}

###############################################################################
#### COMPILATION SUBROUTINES
###############################################################################

sub compile_call {
	# Compiles a filter rule into an iptables rule.
	my %args	= @_;
	my $chain	= coalesce($args{'chain'}, '');
	my $rule	= coalesce($args{'line'}, '');

	# Keep the rule intact in this var for user display if reqd for errors
	my $complete_rule = $rule;

	# Validate input
	&bomb("Invalid input to &compile_call") unless $chain;
	&bomb("Invalid input to &compile_call") unless $rule;

	# See if any variables are used in this rule. If so, call ourself
	# recursively for each element in the var
	if ($rule =~ m/\s$qr_variable\b/) {
		my $var_name = $1;
		foreach (@{$user_var{$var_name}}) {
			my $var_value = $_;
			my $recurse_rule = $rule;
			$recurse_rule =~ s/\s%$var_name\b/ $var_value /;
			&compile_call(chain=>$chain, line=>$recurse_rule);
		}
		# No need to continue from here; Return early.
		return 1;
	}

	my %criteria;		# Hash to store all the individual parts of this rule

	# Extract the individual parts of the rule into our hash
	if ($rule =~ s/$qr_tgt_builtins//s) {
		# iptables inbuilt targets and UC them.
		$criteria{'target'} = uc($1)
	} elsif ($rule =~ s/$qr_first_word//) {;
		# assume it's a user defined target (chain)
		$criteria{'target'} = sprintf('%s%s', $udc_prefix, $1);
	}
	if ($rule =~ s/$qr_kw_ip//s)
		{$criteria{'ipver'} = lc($1)};
	if ($rule =~ s/$qr_kw_protocol//s)
		{$criteria{'proto'} = lc($2)};
	if ($rule =~ s/$qr_kw_in_int//s)
		{$criteria{'i_name'} = $interface{uc($2)}};
	if ($rule =~ s/$qr_kw_out_int//s)
		{$criteria{'o_name'} = $interface{uc($2)}};
	if ($rule =~ s/$qr_kw_src_addr//s)
		{$criteria{'src'} = lc($1)};
	if ($rule =~ s/$qr_kw_dst_addr//s)
		{$criteria{'dst'} = lc($2)};
	if ($rule =~ s/$qr_kw_src_host//s)
		{$criteria{'sgroup'} = $1};
	if ($rule =~ s/$qr_kw_dst_host//s)
		{$criteria{'dgroup'} = $2};
	if ($rule =~ s/$qr_kw_src_range//s) {
		my ($from, $to) = ($1, $2);
		$criteria{'srcrange'} = "$from-$to"};
	if ($rule =~ s/$qr_kw_dst_range//s) {
		my ($from, $to) = ($2, $3);
		$criteria{'dstrange'} = "$from-$to"};
	if ($rule =~ s/$qr_kw_sport//s) {
		my $port = lc($1);
		$criteria{'spt'} = $port;
	}
	if ($rule =~ s/$qr_kw_dport//s) {
		my $port = lc($3);
		$criteria{'dpt'} = $port;
	}
	if ($rule =~ s/$qr_kw_multisport//s) {
		my $ports = lc($1);
		$criteria{'spts'} = $ports;
	}
	if ($rule =~ s/$qr_kw_multidport//s) {
		my $ports = lc($3);
		$criteria{'dpts'} = $ports;
	}
	if ($rule =~ s/$qr_kw_start//s)
		{$criteria{'time_start'} = $1};
	if ($rule =~ s/$qr_kw_finish//s)
		{$criteria{'time_finish'} = $1};
	if ($rule =~ s/$qr_kw_days//s)
		{my @days = split(/,/, $1);
		 foreach my $day (@days) {
			 $criteria{'time_days'} .= substr($day, 0, 2) . ',';
		 }
		 # Strip the trailing comma
		 $criteria{'time_days'} =~ s/,\z//;
	};
	if ($rule =~ s/$qr_kw_every//s)
		{$criteria{'statistics_every'} = $1};
	if ($rule =~ s/$qr_kw_offset//s)
		{$criteria{'statistics_offset'} = $1};
	if ($rule =~ s/$qr_kw_state//s)
		{$criteria{'state'} = uc($1)};
	if ($rule =~ s/$qr_kw_prefix//s)
		{$criteria{'logprefix'} = uc($1)};
	if ($rule =~ s/$qr_kw_limit//s)
		{$criteria{'limit'} = lc($1);
		 $criteria{'burst'} = $3}
	if ($rule =~ s/$qr_kw_type//s)
		{$criteria{'icmp_type'} = lc($1); delete $criteria{'proto'};}
	if ($rule =~ s/$qr_kw_mac_addr//s)
		{$criteria{'mac'} = uc($1)};
	if ($rule =~ s/$qr_kw_noop//s)
		# No-op for Keywords: 'all' 'count'
		{;}

	# aggregate criteria that is part of a single module to one output reference
	# in the output rule
	if (defined($criteria{'time_start'})) {
		$criteria{'time'} .= "--timestart $criteria{'time_start'}"
	}
	if (defined($criteria{'time_finish'})) {
		$criteria{'time'} .= "--timestop $criteria{'time_finish'}"
	}
	if (defined($criteria{'time_days'})) {
		$criteria{'time'} .= "--weekdays $criteria{'time_days'}"
	}
	if (defined($criteria{'statistics_every'})) {
		$criteria{'statistic'} .= "-m statistic --mode nth --every $criteria{'statistics_every'}";
	}
	if (defined($criteria{'statistics_offset'})) {
		$criteria{'statistic'} .= "--packet $criteria{'statistics_offset'}"
	}
	if (defined($criteria{'limit'}) and defined($criteria{'burst'})) {
		$criteria{'limit'} .= " --limit-burst $criteria{'burst'}"
	}

	# make sure we've understood everything on the line, otherwise BARF!
	&unknown_keyword(rule=>$rule, complete_rule=>$complete_rule)
		if (&trim($rule));

	if ($criteria{'sgroup'} or $criteria{'dgroup'}) {
		# recurse ourself for each 'source group' or 'destination group'
		my $addrgrp;
		$addrgrp = $criteria{'sgroup'} if $criteria{'sgroup'};
		$addrgrp = $criteria{'dgroup'} if $criteria{'dgroup'};
		&bomb(sprintf('Unknown address group: %s', $addrgrp))
			unless $addr_group{$addrgrp};

		#my @ag_addresses = split(/\n/, $addr_group{$addrgrp}{'hosts'});
		my @ag_addresses = @{$addr_group{$addrgrp}{'hosts'}};
		foreach (@ag_addresses) {
			my $addr = $_;
			my $recurse_rule = $complete_rule;
			$recurse_rule =~ s/\bgroup $addrgrp\b/address $addr/gi;
			&compile_call(chain=>$chain, line=>$recurse_rule);
		}
		return 1;
	}

	# make a decision if the rule is IPv4, IPv6 or Both
	my $rule_is_ipv4 = 0;
	my $rule_is_ipv6 = 0;
	if ( defined($criteria{ipver}) ) {
		# user specified what we're doing
		if ( $criteria{ipver} eq '4' ) {
			$rule_is_ipv4 = 1;
			$rule_is_ipv6 = 0;
		} elsif ( $criteria{ipver} eq '6' ) {
			$rule_is_ipv4 = 0;
			$rule_is_ipv6 = 1;
		} elsif ( $criteria{ipver} =~ m/\Aboth\z/ ) {
			$rule_is_ipv4 = $rule_is_ipv6 = 1;
		}

		# conflicting information?
		if ( $rule_is_ipv4 == 1 and ! $do_ipv4 )
			{ bomb('Can not compile IPv4 rule when IPv4 is disabled'); }
		if ( $rule_is_ipv6 == 1 and ! $do_ipv6 )
			{ bomb('Can not compile IPv6 rule when IPv6 is disabled'); }
	} else {
		# default to ipv4
		$rule_is_ipv4 = 1;
		$rule_is_ipv6 = 0;
	}

	#############################################
	# build the rule into an iptables command
	my $ipt_rule;
	$ipt_rule .= sprintf('-A %s', $chain);
	$ipt_rule .= sprintf(' -j %s', $criteria{'target'})		if (defined($criteria{'target'}));
	$ipt_rule .= sprintf(' -p %s', $criteria{'proto'})		if (defined($criteria{'proto'}));
	$ipt_rule .= sprintf(' -s %s', $criteria{'src'})		if (defined($criteria{'src'}));
	$ipt_rule .= sprintf(' -d %s', $criteria{'dst'})		if (defined($criteria{'dst'}));
	$ipt_rule .= sprintf(' -i %s', $criteria{'i_name'})		if (defined($criteria{'i_name'}));
	$ipt_rule .= sprintf(' -o %s', $criteria{'o_name'})		if (defined($criteria{'o_name'}));
	$ipt_rule .= sprintf(' --sport %s',	$criteria{'spt'})	if (defined($criteria{'spt'}));
	$ipt_rule .= sprintf(' --dport %s',	$criteria{'dpt'})	if (defined($criteria{'dpt'}));
	$ipt_rule .= sprintf(' -m multiport --sports %s',	$criteria{'spts'})		if (defined($criteria{'spts'}));
	$ipt_rule .= sprintf(' -m multiport --dports %s',	$criteria{'dpts'})		if (defined($criteria{'dpts'}));
	$ipt_rule .= sprintf(' -m mac --mac-source %s',		$criteria{'mac'})		if (defined($criteria{'mac'}));
	$ipt_rule .= sprintf(' -m limit --limit %s',		$criteria{'limit'})		if (defined($criteria{'limit'}));
	$ipt_rule .= sprintf(' -m conntrack --ctstate %s',	$criteria{'state'})		if (defined($criteria{'state'}));
	$ipt_rule .= sprintf(' -m statistic %s',			$criteria{'statistic'})	if (defined($criteria{'statistic'}));
	$ipt_rule .= sprintf(' -m iprange --src-range %s',	$criteria{'srcrange'})	if (defined($criteria{'srcrange'}));
	$ipt_rule .= sprintf(' -m iprange --dst-range %s',	$criteria{'dstrange'})	if (defined($criteria{'dstrange'}));
	$ipt_rule .= sprintf(' -m time %s',					$criteria{'time'})		if (defined($criteria{'time'}));
	$ipt_rule .= sprintf(' --log-prefix "[%s] "',		$criteria{'logprefix'})	if (defined($criteria{'logprefix'}));
	$ipt_rule .= sprintf(' -m comment --comment "husk line %s"', $line_cnt);

	PushRule:
	{
		my $added_something;	# Tracking success

		# Push the rule
		if ( $rule_is_ipv4 ) {
			my $ipt4_rule = $ipt_rule;
			if (defined($criteria{'icmp_type'})) {
				$ipt4_rule .= sprintf(' -p icmp --icmp-type %s', $criteria{'icmp_type'});
			};
			$added_something += &ipt4($ipt4_rule);
		}
		if ($rule_is_ipv6) {
			my $ipt6_rule = $ipt_rule;
			if (defined($criteria{'icmp_type'})) {
				$ipt6_rule .= sprintf(' -p icmpv6 --icmpv6-type %s', $criteria{'icmp_type'});
			};
			$added_something += &ipt6($ipt6_rule);
		}

		# Did we succeed?
		unless ( $added_something ) {
			&warn(sprintf(
				"The following rule did NOT compile successfully:\n\tLine %u ==> %s",
				$line_cnt,
				$complete_rule,
			));
		}
	}

	return 1;
}

sub compile_nat {
	# Compiles a 'map' rule into an iptables DNAT and SNAT rule.
	my($rule) = @_;
	my $complete_rule = $rule;

	# strip out the leading 'common' keyword
	$rule =~ s/$qr_tgt_map//s;
	$rule =~ &cleanup_line($rule);

	# Hash to store all the individual parts of this rule
	my %criteria;

	if ($rule =~ s/$qr_kw_in_int//s)
		{$criteria{'in'}	= uc($2)}
	if ($rule =~ s/$qr_kw_protocol//s)
		{$criteria{'proto'}	= lc($2)}
	if ($rule =~ s/$qr_kw_dst_addr//s)
		{$criteria{'inet_ext'}	= lc($2)}
	if ($rule =~ s/$qr_kw_sport//s) {
		my $port = lc($1);
		$criteria{'sport_ext'} = $port;
	}
	if ($rule =~ s/$qr_kw_dport//s) {
		my $port = lc($3);
		$criteria{'dport_ext'} = $port;
	}
	if ($rule =~ s/$qr_kw_multisport//s) {
		my $ports = lc($1);
		$criteria{'sports_ext'} = $ports;
	}
	if ($rule =~ s/$qr_kw_multidport//s) {
		my $ports = lc($3);
		$criteria{'dports_ext'} = $ports;
	}
	if ($rule =~ s/to ([^: ]+)(:([0-9]+))?\b//si)
		{$criteria{'inet_int'}	= $1}
	if ($rule =~ s/to ([^: ]+)(:([0-9]+))?\b//si)
		{$criteria{'port_int'}	= $3}

	# make sure we've understood everything on the line, otherwise BARF!
	&unknown_keyword(rule=>$rule, complete_rule=>$complete_rule)
		if (&trim($rule));

	# DNAT with the criteria defined
	&ipt4(&collapse_spaces(sprintf(
			'-t nat -A PREROUTING %s %s %s %s %s %s %s -j DNAT %s%s',
			$criteria{'in'}			? "-i $interface{$criteria{'in'}}"					: '',
			$criteria{'proto'}		? "-p $criteria{'proto'}"							: '',
			$criteria{'inet_ext'}	? "-d $criteria{'inet_ext'}"						: '',
			$criteria{'sport_ext'}	? "--sport $criteria{'sport_ext'}"					: '',
			$criteria{'dport_ext'}	? "--dport $criteria{'dport_ext'}"					: '',
			$criteria{'sports_ext'}	? "-m multiport --sports $criteria{'sports_ext'}"	: '',
			$criteria{'dports_ext'}	? "-m multiport --dports $criteria{'dports_ext'}"	: '',
			$criteria{'inet_int'}	? "--to $criteria{'inet_int'}"						: '',
			$criteria{'port_int'}	? ":$criteria{'port_int'}"							: '',
		)));
	# SNAT with the criteria inversed (ie, dest become source and vice-versa)
#	&ipt4(&collapse_spaces(sprintf(
#			'-t nat -A POSTROUTING %s %s %s %s %s %s %s -j SNAT %s',
#			$criteria{'in'}			? "-o $interface{$criteria{'in'}}"					: '',
#			$criteria{'proto'}		? "-p $criteria{'proto'}"							: '',
#			$criteria{'inet_int'}	? "-s $criteria{'inet_int'}"						: '',
#			$criteria{'sport_ext'}	? "--dport $criteria{'sport_ext'}"					: '',
#			$criteria{'dport_ext'}	? "--sport $criteria{'dport_ext'}"					: '',
#			$criteria{'sports_ext'}	? "-m multiport --dports $criteria{'sports_ext'}"	: '',
#			$criteria{'dports_ext'}	? "-m multiport --sports $criteria{'dports_ext'}"	: '',
#			$criteria{'inet_ext'}	? "--to $criteria{'inet_ext'}"						: '',
#		)));
}

sub compile_interception {
	# Compiles a 'redirect' or 'intercept' rule into an iptables REDIRECT rule.
	my($rule) = @_;
	my $complete_rule = $rule;

	# strip out the leading 'common' keyword
	$rule =~ s/$qr_tgt_redirect//s;
	$rule =~ &cleanup_line($rule);

	if ( ! $do_ipv4 ) {
		# can only nat ipv4
		&bomb('redirect/intercept rules only available for ipv4');
	}

	# Hash to store all the individual parts of this rule
	my %criteria;

	if ($rule =~ s/$qr_kw_in_int//s)
		{$criteria{'in'}	= uc($2)}
	if ($rule =~ s/$qr_kw_protocol//s)
		{$criteria{'proto'}	= lc($2)}
	if ($rule =~ s/$qr_kw_dst_addr//s)
		{$criteria{'inet_ext'}	= lc($2)}
	if ($rule =~ s/$qr_kw_sport//s) {
		my $port = lc($1);
		$criteria{'spt'} = $port;
	}
	if ($rule =~ s/$qr_kw_dport//s) {
		my $port = lc($3);
		$criteria{'dpt'} = $port;
	}
	if ($rule =~ s/$qr_kw_multisport//s) {
		my $ports = lc($1);
		$criteria{'spts'} = $ports;
	}
	if ($rule =~ s/$qr_kw_multidport//s) {
		my $ports = lc($3);
		$criteria{'dpts'} = $ports;
	}
	if ($rule =~ s/to ([0-9]+)\b//si)
		{$criteria{'port_redir'} = $1}

	# make sure we've understood everything on the line, otherwise BARF!
	&unknown_keyword($rule, $complete_rule) if (&trim($rule));

	my $ipt_rule = &collapse_spaces(sprintf(
		'-t nat -A PREROUTING %s %s %s %s %s -j REDIRECT %s',
		$criteria{'in'}			? "-i $interface{$criteria{'in'}}"	: '',
		$criteria{'proto'}	  	? "-p $criteria{'proto'}"			: '',
		$criteria{'inet_ext'}   ? "-d $criteria{'inet_ext'}"		: '',
		$criteria{'spt'}		? "--sport $criteria{'spt'}"		: '',
		$criteria{'dpt'}		? "--dport $criteria{'dpt'}"		: '',
		$criteria{'spts'}		? "-m multiport --sports $criteria{'spts'}"		: '',
		$criteria{'dpts'}		? "-m multiport --dports $criteria{'dpts'}"		: '',
		$criteria{'port_redir'} ? "--to $criteria{'port_redir'}"	: '',
	));
	&ipt4($ipt_rule);
}

sub compile_common {
	# Compiles a 'common' rule into an iptables rule.
	my ($line) = @_;

	my $qr_OPTS			= qr/\b?(.+)?/o;
	my $qr_CMN_NAT		= qr/\Anat ($qr_int_name)/io;	# No \z on here because there's extra processing done in the if block
	my $qr_CMN_LOOPBACK	= qr/\Aloopback\z/io;
	my $qr_CMN_SYN		= qr/\Asyn\s($qr_int_name)\z/io;
	my $qr_CMN_SPOOF	= qr/\Aspoof ($qr_int_name)$qr_OPTS\z/io;
	my $qr_CMN_BOGON	= qr/\Abogon ($qr_int_name)$qr_OPTS\z/io;	# TODO: Use options for 'nolog'
	my $qr_CMN_PORTSCAN	= qr/\Aportscan ($qr_int_name)\z/io;
	my $qr_CMN_XMAS		= qr/\Axmas ($qr_int_name)\z/io;

	# strip out the leading 'common' keyword
	$line =~ s/$qr_tgt_common//s;
	$line = &cleanup_line($line);

	if ($line =~ m/$qr_CMN_NAT/) {
		&bomb('NAT specified in rules, but IPv4 is disabled and IPv6 does not allow NAT') unless ($do_ipv4);

		# SNAT traffic out a given interface
		my $snat_oeth = uc($1);
		my $snat_chain = sprintf('snat_%s', $snat_oeth);

		# Validate
		&bomb(sprintf('Invalid interface specified for SNAT: %s', $snat_oeth))
			unless ($interface{$snat_oeth});

		# Create a SNAT chain for this interface
		&ipt4(sprintf('-t nat -N %s', $snat_chain));

		# Only specific sources?
		my $snat_src;
		if ($line =~ s/\b(source|src)( address(es)?)?\s+($qr_ip4_cidr)\b//si) {
			$snat_src = $4;
			&warn('common NAT rule found specifying source address; Not supported yet');
		}

		# Work out if we're SNAT'ing or MASQUERADING
		my $snat_ip;
		if ($line =~ s/\bto\s+($qr_ip4_address)\b//si) {
			$snat_ip = $1;
		}

		# Add SNAT rules to the SNAT chain
		if ($snat_ip) {
			# User specified a SNAT address
			&ipt4(&collapse_spaces(sprintf(
					'-t nat -A %s -j SNAT --to %s -m comment --comment "husk line %s"',
					$snat_chain,
					$snat_ip,
					$line_cnt,
			)));
		} else {
			# Default to MASQUERADE
			# This allows the 'src' argument in the kernel to
			# be used to specify the source address used for
			# outgoing packets. Useful in configurations where
			# HA is used, and there is a 'src' argument to tell
			# the kernel to prefer the Virtual Address as the
			# source.
			&ipt4(&collapse_spaces(sprintf(
					'-t nat -A %s -j MASQUERADE -m comment --comment "husk line %s"',
					$snat_chain,
					$line_cnt,
			)));
		}

		# Call the snat chain from POSTROUTING for private addresses
		foreach my $rfc1918 (qw(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16)) {
			&ipt4(sprintf('-t nat -A POSTROUTING -o %s -s %s -j %s -m comment --comment "husk line %s"',
					$interface{$snat_oeth},
					$rfc1918,
					$snat_chain,
					$line_cnt,
			));
		}
	}
	elsif ($line =~ m/$qr_CMN_LOOPBACK/) {
		# loopback accept
			&ipt(sprintf('-A INPUT -i lo -j ACCEPT -m comment --comment "husk line %s"', $line_cnt));
			# Loopback is a different address between IPv4 and IPv6
			&ipt4(sprintf('-A INPUT ! -i lo -s %s -j DROP -m comment --comment "husk line %s"', '127.0.0.0/8', $line_cnt));
			&ipt6(sprintf('-A INPUT ! -i lo -s %s -j DROP -m comment --comment "husk line %s"', '::1/128', $line_cnt));
			&ipt(sprintf('-A OUTPUT -o lo -j ACCEPT -m comment --comment "husk line %s"', $line_cnt));
	}
	elsif ($line =~ m/$qr_CMN_SYN/) {
		# syn protections
		my $iface = $1;

		# Validate
		&bomb(sprintf('Invalid interface specified for SYN Protection: %s', $iface))
			unless ($interface{$iface});

		push(@syn_protection, $iface);
	}
	elsif ($line =~ m/$qr_CMN_SPOOF/) {
		# antispoof rule
		my $iface = $1;
		my $src = &trim($2);

		# Validate
		&bomb(sprintf('Invalid interface specified for Spoof Protection: %s', $iface))
			unless ($interface{$iface});

		# antispoof configuration is stored in a hash of arrays
		# then processed into iptables commands in &close_rules
		# Example:
		#   {DMZ} => ( 1.2.3.0/24 )
		#   {LAN} => ( 10.0.0.0/24 10.0.1.0/24 )
		push(@{$spoof_protection{$iface}}, $src);
	}
	elsif ($line =~ m/$qr_CMN_BOGON/) {
		# antibogon rule
		# The term "bogon" stems from hacker jargon, where it is defined
		# as the quantum of "bogosity", or the property of being bogus.
		my $iface = $1;

		# Validate
		&bomb(sprintf('Invalid interface specified for Bogon Protection: %s', $iface))
			unless ($interface{$iface});

		push(@bogon_protection, $iface);
	}
	elsif ($line =~ m/$qr_CMN_PORTSCAN/) {
		# portscan protection
		my $iface = $1;

		# Validate
		&bomb(sprintf('Invalid interface specified for Portscan Protection: %s', $iface))
			unless ($interface{$iface});

		push(@portscan_protection, $iface);
	}
	elsif ($line =~ m/$qr_CMN_XMAS/) {
		# xmas packet rule
		my $iface = $1;

		# Validate
		&bomb(sprintf('Invalid interface specified for Xmas Protection: %s', $iface))
			unless ($interface{$iface});

		push(@xmas_protection, $iface);
	} else {
		&bomb('Unrecognized "common" rule: '.$line);
	}
}

###############################################################################
#### INITIALIZATION SUBROUTINES
###############################################################################

sub read_config_file {
	my %args = @_;
	my $fname = $args{'fname'};

	# Validate what was passed
	&bomb((caller(0))[3] . ' called without passing $fname') unless $fname;

	# make sure the file exists first
	&bomb(sprintf('Configuration file not found: %s', $fname))
		unless (-f $fname);

	my $cfg = new Config::Simple($fname);
	my %config;
	if ( $cfg ) {
		%config = $cfg->vars();
	}
	$conf_dir			= coalesce($config{'default.conf_dir'},			$conf_defaults{conf_dir});
	$iptables			= coalesce($config{'default.iptables'},			$conf_defaults{iptables});
	$ip6tables			= coalesce($config{'default.ip6tables'},		$conf_defaults{ip6tables});
	$udc_prefix			= coalesce($config{'default.udc_prefix'}, 		$conf_defaults{udc_prefix});
	$do_ipv4			= coalesce($config{'default.ipv4'}, 			$conf_defaults{ipv4});
	$do_ipv6			= coalesce($config{'default.ipv6'}, 			$conf_defaults{ipv6});
	$ignore_autoconf	= coalesce($config{'default.ignore_autoconf'},	$conf_defaults{ignore_autoconf});
	$old_state_track	= coalesce($config{'default.old_state_track'},	$conf_defaults{old_state_track});
	chomp($conf_dir);
	chomp($iptables)			if ($iptables);
	chomp($ip6tables)			if ($ip6tables);
	chomp($udc_prefix);
	chomp($do_ipv4);
	chomp($do_ipv6);
	chomp($ignore_autoconf);
	chomp($old_state_track);

	# validate config
	{
		# strip trailing slash from conf_dir
		$conf_dir =~ s/\/*\z//g;

		# check everything actually exists
		&bomb(sprintf('Configuration dir not found: %s', $conf_dir))
			unless (-d $conf_dir);
		if ($do_ipv4) {
			&bomb(sprintf('Could not find iptables binary: %s', $iptables ? $iptables : 'NOT FOUND'))
				unless ($iptables and -x $iptables);
		}
		if ($do_ipv6) {
			&bomb(sprintf('Could not find ip6tables binary: %s', $ip6tables ? $ip6tables : 'NOT FOUND'))
				unless ($ip6tables and -x $ip6tables);
		}
	}

	# anything we didn't understand?
	foreach my $conf_key (keys %config) {
		my ($section, $key) = split(/\./, $conf_key);
		&bomb('Unknown setting in config file: '.$key)
			unless (defined($conf_defaults{$key}));
	}
}

sub load_addrgroups {
	# Access the array of hosts by:
	#   foreach (@{$addr_group{'rfc1918'}{'hosts'}}) {
	my %args = @_;
	my $fname = $args{'fname'};

	# Validate what was passed
	&bomb((caller(0))[3] . ' called without passing $fname') unless $fname;

	if ( -f $fname) {
		tie %addr_group, 'Config::IniFiles', ( -file => $fname );
	}
}

sub load_interfaces {
	# Loads interfaces.conf file. This file maps
	# symbolic names to actual devices.
	# Example:
	#   LAN => eth1
	#   DMZ => eth2
	#   NET => ppp0
	my %args = @_;
	my $fname = $args{'fname'};

	my $qr_NAME_ZONE = qr/\Azone\s+(\w+)\s+is\s+($qr_if_names)\b?\z/io;

	# Validate what was passed
	&bomb((caller(0))[3] . ' called without passing fname') unless $fname;

	my @file_lines;
	open(INTFILE, $fname) or &bomb("Failed to read $fname");
	@file_lines = <INTFILE>;
	close(INTFILE);

	InterfacesLoop:
	foreach my $line (@file_lines) {
		chomp($line);
		my($int, $name);

		# strip comments
		$line = &cleanup_line($line);

		# ignore if the line is blank
		next InterfacesLoop unless $line;

		# strip the path from the input filename (for error messages)
		my $short_fname = &basename($fname);

		if ($line =~ m/$qr_NAME_ZONE/) {
			$name	= uc($1);
			$int	= $2;
		} else {
			&bomb(sprintf('Bad config in "%s": %s', $fname, $line))
		}

		# make sure it's not already defined
		&bomb(sprintf('Zone "%s" defined twice in "%s"', $name, $short_fname))
			if ($interface{$name});
		for my $i ( keys %interface ) {
			&bomb(sprintf('Interface "%s" named twice in "%s"', $int, $short_fname))
				if ($interface{$i} =~ m/\A$int\z/);
		}

		# add to the hash
		$interface{$name} = $int;
	}

	# Make sure we have a ME = lo definition
	&bomb(sprintf('Interface "lo" must be defined as "ME" in "%s"', $fname))
		unless ($interface{'ME'} =~ m/\Alo\z/);
}

sub handle_cmd_args {
	GetOptions(
		"c|conf=s"	=> \$conf_file,
		"4|ipv4"	=> \$do_ipv4,
		"6|ipv6"	=> \$do_ipv6,
		"no-ipv6-comments"	=> \$disable_ipv6_comments,
	) or &usage();
}

sub init {
	# reset policies to ACCEPT
	foreach my $chain (qw(INPUT OUTPUT FORWARD)) {
		&ipt("-P $chain ACCEPT");
	}

	# wipe everything so we know we are starting fresh. we use 2 loops here
	# because IPv6 doesn't have a "nat" table.
	foreach my $table (qw(filter nat mangle raw)) {
		&ipt4("-t $table -F");	# Flush all rules in all chains
		&ipt4("-t $table -X");	# Delete all user-defined chains
		&ipt4("-t $table -Z");	# Reset counters
	}
	foreach my $table (qw(filter mangle raw)) {
		&ipt6("-t $table -F");	# Flush all rules in all chains
		&ipt6("-t $table -X");	# Delete all user-defined chains
		&ipt6("-t $table -Z");	# Reset counters
	}

	# add standard rules
	foreach my $chain (qw(INPUT FORWARD OUTPUT)) {
		&ipt(sprintf('-A %s -m conntrack --ctstate ESTABLISHED -j ACCEPT',	$chain));
		&ipt(sprintf('-A %s -m conntrack --ctstate RELATED -j ACCEPT',		$chain));
	}
}

###############################################################################
#### HELPER SUBROUTINES
###############################################################################

sub include_file {
	my ($fname) = @_;

	# Validate what was passed
	&bomb((caller(0))[3] . ' called without passing $fname') unless $fname;

	$fname = &trim($fname);

	# prepend $conf_dir if we're given a relative filename
	$fname = ($conf_dir.'/'.$fname) unless ($fname =~ m/^\//g);

	# Store our current file details;
	my $orig_fname = $current_rules_file;
	my $orig_line_count = $line_cnt;

	# Parse the include file;
	&read_rules_file($fname);

	# Restore our details
	$line_cnt = $orig_line_count;
	$current_rules_file = $orig_fname;
}

sub unknown_keyword {
	my %args = @_;
	my $rule = $args{'rule'};
	my $complete_rule = $args{'complete_rule'};

	# Validate what was passed
	&bomb((caller(0))[3] . ' called without passing $rule')
		unless $rule;
	&bomb((caller(0))[3] . ' called without passing $complete_rule')
		unless $complete_rule;

	my $unknown_keyword;
	$rule =~ m/^\s*(\S+)+\b/; $unknown_keyword = $1;
	$complete_rule =~ m/\b$unknown_keyword\b/; my $pos = length($`) + 1;
	&bomb(sprintf(
		"Unknown keyword(s) or invalid syntax found: %s\n\t%s\n\t%${pos}s-- HERE",
		&trim($rule),
		$complete_rule,
		'^'));
}

sub ipt {
	# add a new rule for both IPv4 and IPv6
	my ($line) = @_;
	&ipt4($line);
	&ipt6($line);
}

sub ipt4 {
	my ($line) = @_;
	return unless ($do_ipv4);
	push(@ipv4_rules, $line);
}

sub ipt6 {
	my ($line) = @_;
	return unless ($do_ipv6);
	if ($disable_ipv6_comments) {
		# Early versions of ip6tables did not include support for the 'comment'
		# module (eg, CentOS 5.x) so we need to exclude them sometimes.
		$line =~ s/-m comment --comment ("|')[^\1]+\1//;
	}
	push(@ipv6_rules, $line);
}

sub is_bridged {
	# See if an interface belongs to a bridge
	my %args = @_;
	my $eth = $args{'eth'};

	# Validate what was passed
	&bomb((caller(0))[3] . ' called without passing $eth') unless $eth;

	# If the interface has a '+' then it's a wildcard so we
	# need to take it out and let the regex below handle it.
	$eth =~ s/\+\z//;

	my $bridges = `brctl show 2> /dev/null`;
	return 1 if ($bridges =~ m/\b$eth$/m);
	return 1 if ($bridges =~ m/\b$eth((\d|\.|:)+)?$/m);
	return;
}

###############################################################################
#### STRING HELPERS
###############################################################################
sub basename {
	my ($s) = @_;
	$s =~ s/\A.*\///;
	return $s;
}

sub collapse_spaces {
	# Collapse multiple spaces into a single
	# space in the supplied string.
	my ($string) = @_;
	return $string = join(' ', split(' ', $string));
}

sub trim {
	my $string = shift;
	$string =~ s/\A\s+//;
	$string =~ s/\s+\z//;
	return $string;
}

sub cleanup_line {
	my ($line) = @_;
	# Strip Comments and Trim
	$line =~ s/\s*#.*\z//;
	$line = &trim($line);
}

sub coalesce {
	# Perl 5.10 supports a proper coalesce operator (//) but
	# it isn't widely packaged and distributed yet (well, I've
	# only checked CentOS, but that's where I use husk, so until
	# Perl 5.10 is more widely used, we'll do our own
	# coalescing here.
	my @args = @_;
	foreach my $val (@args) {
		return $val if defined($val);
	}
	return;
}

sub timestamp {
	my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst)=localtime(time);
	return sprintf(
		"%4d-%02d-%02d %02d:%02d:%02d",
		$year+1900, $mon+1, $mday, $hour, $min, $sec
	);
}

###############################################################################
#### IPv6 HELPERS
###############################################################################
sub make_ipv6_regex {
	# Taken from CPAN Regexp::IPv6 by Salvador Fandiño García
	my $IPv4 = "((25[0-5]|2[0-4][0-9]|[0-1]?[0-9]{1,2})[.](25[0-5]|2[0-4][0-9]|[0-1]?[0-9]{1,2})[.](25[0-5]|2[0-4][0-9]|[0-1]?[0-9]{1,2})[.](25[0-5]|2[0-4][0-9]|[0-1]?[0-9]{1,2}))";
	my $G = "[0-9a-fA-F]{1,4}";

	my @tail = (
		":",
		"(:($G)?|$IPv4)",
		":($IPv4|$G(:$G)?|)",
		"(:$IPv4|:$G(:$IPv4|(:$G){0,2})|:)",
		"((:$G){0,2}(:$IPv4|(:$G){1,2})|:)",
		"((:$G){0,3}(:$IPv4|(:$G){1,2})|:)",
		"((:$G){0,4}(:$IPv4|(:$G){1,2})|:)" );

	my $IPv6_re = $G;
	$IPv6_re = "$G:($IPv6_re|$_)" for @tail;
	$IPv6_re = qq/:(:$G){0,5}((:$G){1,2}|:$IPv4)|$IPv6_re/;
	$IPv6_re =~ s/\(/(?:/g;
	#$IPv6_re = qr/$IPv6_re/;
	return $IPv6_re;
}

###############################################################################
#### MISC HELPERS
###############################################################################
sub bomb {
	# Error handling; Yay!
	my ($msg) = @_; $msg = 'Unspecified Error' unless $msg;
	if ($line_cnt) {
		printf STDERR ("BOMBS AWAY (Line %u in %s): %s\n", $line_cnt, $current_rules_file, $msg);
	} else {
		printf STDERR ("BOMBS AWAY: %s\n", $msg);
	}
	exit 1;
}

sub warn() {
	# Show warning to user
	my ($msg) = @_; $msg = 'Unspecified Error' unless $msg;
	print STDERR "WARNING: $msg\n";
}

sub dbg {
	# Debug Helper
	my ($msg) = @_; $msg = 'Unspecified Error' unless $msg;
	print STDERR "DEBUG: $msg\n";
}

sub usage {
	print "Usage: husk [options]\n";
	print "Options:\n";
	printf "   %-25s %-50s\n", '--script', 'output an iptables script instead of iptables commands';
	printf "   %-25s %-50s\n", '--conf=/path/to/husk.conf', 'specify an alternate config file';
	printf "   %-25s %-50s\n", '--ipv6', 'generate ipv6 output';
	exit 1;
}

__END__

###############################################################################
### POD DOCUMENTATION MARKUP
###############################################################################

=head1 NAME

husk - iptables firewall compiler with IPv4 and IPv6 support

=head1 SYNOPSIS

husk [OPTIONS]

Without any options, husk will look for a configuration file in /etc/husk/ and
attempt to compile the firewall rules into iptables syntax, writing its output
to stdout

=head1 DESCRIPTION

husk is a natural language wrapper around the Linux iptables packet filtering
engine (iptables). It is designed to abstract the sometimes confusing syntax of
iptables, allowing use of rules that have better readability, and expressed in
a more 'freeform' and reusable fashion compared to normal 'raw' iptables rules.

husk can be used on either firewall/router computers (with multiple network
interfaces), or standalone systems (with one network interface)

Each interface (real or virtual) is called a 'zone' in husk. Zones are given a
friendly name which is what is used in the rule definitions. This abstracts the
Linux device names (eg, eth0, ppp0, bond0 etc) into much more intuitive names
such as NET, LAN and DMZ. This has the added benefit of moving interfaces in
the future can be done simply by changing the name-to-device mapping.

=head2 fire script

It is suggested to use the supplied "fire" script when loading your rules. This
script provides several functions:

=over 4

=item * Compiles your rule file(s) ready to activate

=item * Saves the live rules to a temporary file to allow rollback

=item * Attempts to load the new rules (non-atomically; see below)

=item * Asks you for confirmation that the rules loaded successfully. If
confirmation is not given, rollback to previous rules is initiated after a
timeout.

=item * Calls the iptables/ip6tables init script to save the new rules so they
are loaded again at next reboot.

=back

=head2 Atomic loading of rules

It has been consciously considered and decided AGAINST atomic loading of rules
using iptables-restore for several reasons:

=over 4

=item * Compiling to the format required by iptables-restore is more
complicated than for the regular iptables command.

=item * iptables-restore (currently) does not give much useful information
about errors if there is a problem with the rules it is loaded. This makes
debug much more difficult than seeing exactly which rule failed when running
multiple plain iptables commands.

=item * With atomic reload, a single bad rule will prevent all rules from being
loaded. With plain iptables commands, only the invalid rule(s) aren't loaded.

=back

=head1 OPTIONS

=over 4

=item -c, --conf

Path to configuration file to use.
Default: C</etc/husk/husk.conf>

=item -h, --help

Show terse help and and exit.

=item -V, --version

Show the version and exit.

=back

=head1 CONFIGURATION

By default, configuration lives in C</etc/husk/husk.conf>. This is your normal
style configuration with key = value options. Comments are supported and begin
with a hash (#) continuing to the end of the line.

The following directives are supported:

=over 4

=item C<conf_dir> = /etc/husk/

Location where configuration, rules etc are found. Not very well tested so it's
probably best to just leave it as the default by commenting this option
completely.

=item C<rules_file> = rules.conf

The filename of your rules. You could have several sets of rules (rules1.conf
to rulesN.conf) and switch between them by changing this configuration option.

=item C<udc_prefix>

This prefix is prefixed to User-Defined Chains (UDC) that husk generates. This
applies to any chains created using a 'define rules' block that isn't a
cross-zone match. For example, 'define rules BLACKLIST' will be called
'prefix_BLACKLIST', by default 'sbrt_BLACKLIST'. Having a common prefix helps
sort output and identify generated rules, as well as avoid potential name
collisions with in-built chains.

=item C<ipv4>

A boolean value (1 or 0) to set if husk should generate output for IPv4 (eg,
iptables).

=item C<ipv6>

A boolean value (1 or 0) to set if husk should generate output for IPv6 (eg,
ip6tables).

=item C<ignore_autoconf>

Sometimes devices like to autoconfigure themselves using RFC3927. Personally I
find this to be annoying and I don't want the anti-spoof rules to log this
traffic. Setting c<ignore_autoconf> to 1 will add rules to the anti-spoof
chains to silently DROP autoconfig traffic before those packets hit the LOG
rules. This is a boolean value (1 or 0).

=item C<old_state_track>

By default, husk generated rules using the 'conntrack' module and the 'ctstate'
flag when generating rules involving connection state. Some distributions still
don't include the 'conntrack' / 'ctstate' option so you can override this
behaviour by setting 'old_state_track' to 1. This is a boolean value (1 or 0).

=item C<iptables>

The path to iptables binary on your system. Usually C</sbin/iptables> or
C</usr/sbin/iptables> depending on your distribution.

=item C<ip6tables>

The path to ip6tables binary on your system. Usually C</sbin/ip6tables> or
C</usr/sbin/ip6tables> depending on your distribution.

=back

=head1 EXAMPLES

	husk | sh

Using the associated "fire" script:

	fire

	fire --no-ipv6-comments

=head1 HELPERS

Several helpers have been supplied with husk to assist with firewalling common
ports/applications such as:

=over 4

=item * Apple IOS Devices

=item * DHCP

=item * DNS

=item * Email Ports

=item * Windows (Active Directory, CIFS/Samba etc)

=item * SQL Applications

=back

Check in the C<helpers/> path for others.

=head2 Using Helpers

Using helpers is a 2 step process:

=over 4

=item 1. Include the helper file with the C<include /path/to/helper> directive

=item 2. Use the chains that helper creates.

=back

Refer to the example rules below to see it in action (eg, the ICMP helper).

=head1 RULES SYNTAX

To be completed.

=head2 Targets

Targets are the first part of any rule. They are be either a built-in (i.e.,
accept, drop, reject, log) or the name of a 'define rules' written elsewhere
in the rules file.

=over 4

=item * accept

Packets matching this rule should be ACCEPTED

=item * drop

Packets matching this rule should be DROPPED. This makes the packet dissappear
without any notification to the source address.

=item * reject

Packets matching this rule should be REJECTED. This sends an appropriate ICMP
notification packet to the source address.

=item * log

Packets matching this rule should be sent to the kernel log. Specific options:

=over 4

=item * prefix "string"

Log with a specific string for identification.

=back

=back

=head2 EXAMPLES

This set of example rules is for a simple firewall/router machine.

	include helpers/icmp.conf
	include helpers/gotomeeting.conf
	include helpers/samba.conf
	
	define rules LAN to NET
	GOTOMEETING source address 192.168.100.100
	SAMBA destination address cifs.example.com
	accept all	# Allow everything from local network
	end define
	
	define rules LAN to ME
	accept protocol tcp ports ssh,smtp,domain
	accept protocol udp ports ntp,domain
	accept protocol udp ports bootps,bootpc	# Allow clients to DHCP
	end define
	
	define rules INPUT
	ICMP all protocol icmp
	end define
	
	define rules OUTPUT
	# Refer to CAVEATS below.
	reject state new protocol tcp port 6667:6669	# No IRC from this box
	accept all
	end define
	
	define rules FORWARD
	ICMP all protocol icmp
	drop protocol tcp ports 135,137,138,139,445	# ignore annoying windows traffic
	drop protocol udp ports 135,137,138,139,445	# ignore annoying windows traffic
	# Allow bounce routing
	accept in LAN out LAN
	end define
	
	# Standard stuff
	common loopback
	common nat NET
	common bogon NET
	common portscan NET
	common xmas NET
	common syn NET
	common spoof LAN 10.0.0.0/24

=head1 CAVEATS

=over 4

=item * Remember the default policy for ALL chains in the 'filter' table is
DROP. THIS INCLUDES 'OUTPUT' so you need to explicitly allow (or write
appropriate rules for) outbound traffic. See example rules above.

=item * Early implementations of the IPv6 version of iptables (ip6tables) did
NOT support the 'comment' module. This module is used on EVERY rule to identify
where in the source file it was generated from. If you are using husk with an
early version of ip6tables, you need to use the --disable-ipv6-comments option.

=back

=head1 BUGS

=head2 Reporting Bugs

Email bug reports to <fukawi2@gmail.com>

=head2 Known Bugs

None. Refer to "Reporting Bugs" ;)

=head1 ACKNOWLEDGEMENTS

Thanks to Mike Sampson for his assistance in adding and testing IPv6 support.

=head1 LICENSE

Copyright 2010-2011 Phillip Smith

Made available under the conditions of the GPLv2. This is free software; refer
to the F<LICENSE> file for details.

=head1 AVAILABILITY

<http://www.huskfw.info/>

<http://github.com/fukawi2/husk/>

=head1 AUTHOR

Phillip Smith aka fukawi2

=head1 SEE ALSO

netfilter homepage:
<http://www.netfilter.org/>

=head2 IPv4 AND GENERAL REFERENCES

RFC919; Broadcasting Internet Datagrams:
<http://www.ietf.org/rfc/rfc919.txt>

RFC1112; Host Extensions for IP Multicasting:
<http://www.ietf.org/rfc/rfc1112.txt>

RFC1122; Requirements for Internet Hosts (Communication Layers):
<http://www.ietf.org/rfc/rfc1122.txt>

RFC1166; Internet Numbers:
<http://www.ietf.org/rfc/rfc1166.txt>

RFC1918; Address Allocation for Private Internets:
<http://www.ietf.org/rfc/rfc1918.txt>

RFC2544; Benchmarking Methodology for Network Interconnect Devices:
<http://www.ietf.org/rfc/rfc2544.txt>

RFC3927; Dynamic Configuration of IPv4 Link-Local Addresses:
<http://www.ietf.org/rfc/rfc3927.txt>

RFC5736; IANA IPv4 Special Purpose Address Registry:
<http://www.ietf.org/rfc/rfc5736.txt>

RFC5737; IPv4 Address Blocks Reserved for Documentation:
<http://www.ietf.org/rfc/rfc5737.txt>

=head2 IPv6 REFERENCES

RFC3879; Deprecating Site Local Addresses:
<http://www.ietf.org/rfc/rfc3879.txt>

RFC4291; IP Version 6 Addressing Architecture:
<http://www.ietf.org/rfc/rfc4291.txt>

RFC4548; Internet Code Point (ICP) Assignments for NSAP Addresses:
<http://www.ietf.org/rfc/rfc4548.txt>

RFC4048; RFC 1888 Is Obsolete:
<http://www.ietf.org/rfc/rfc4048.txt>

RFC1888; OSI NSAPs and IPv6:
<http://www.ietf.org/rfc/rfc1888.txt>

RFC4193; Unique Local IPv6 Unicast Addresses:
<http://www.ietf.org/rfc/rfc4193.txt>

=cut

# vim: noexpandtab sw=4 ts=4
