#!/usr/bin/perl

################################################################
#
#  Copyright notice
#
#  (c) 2005-20011
#  Copyright: Rudolf Koenig (r dot koenig at koeniglich dot de)
#  All rights reserved
#
#  This script free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  The GNU General Public License can be found at
#  http://www.gnu.org/copyleft/gpl.html.
#  A copy is found in the textfile GPL.txt and important notices to the license
#  from the author is found in LICENSE.txt distributed with these scripts.
#
#  This script is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  This copyright notice MUST APPEAR in all copies of the script!
#  Thanks for Tosti's site (<http://www.tosti.com/FHZ1000PC.html>)
#  for inspiration.
#
#  Homepage:  http://fhem.de


use strict;
use warnings;
use IO::Socket;
use Time::HiRes qw(gettimeofday);


##################################################
# Forward declarations
#
sub AddDuplicate($$);
sub AnalyzeCommand($$);
sub AnalyzeCommandChain($$);
sub AnalyzePerlCommand($$);
sub AnalyzeInput($);
sub AssignIoPort($);
sub AttrVal($$$);
sub addToAttrList($);
sub CallFn(@);
sub CommandChain($$);
sub CheckDuplicate($$);
sub DoClose($);
sub DoTrigger($$);
sub Dispatch($$$);
sub FmtDateTime($);
sub FmtTime($);
sub GetLogLevel(@);
sub GetTimeSpec($);
sub HandleArchiving($);
sub HandleTimeout();
sub IOWrite($@);
sub InternalTimer($$$$);
sub LoadModule($);
sub Log($$);
sub OpenLogfile($);
sub PrintHash($$);
sub ReadingsVal($$$);
sub ReplaceEventMap($$$);
sub ResolveDateWildcards($@);
sub RemoveInternalTimer($);
sub SecondsTillTomorrow($);
sub SemicolonEscape($);
sub SignalHandling();
sub TimeNow();
sub WriteStatefile();
sub XmlEscape($);
sub devspec2array($);
sub doGlobalDef($);
sub fhem($);
sub fhz($);
sub IsDummy($);
sub IsIgnored($);
sub setGlobalAttrBeforeFork();
sub redirectStdinStdErr();

sub CommandAttr($$);
sub CommandDefaultAttr($$);
sub CommandDefine($$);
sub CommandDeleteAttr($$);
sub CommandDelete($$);
sub CommandGet($$);
sub CommandHelp($$);
sub CommandInclude($$);
sub CommandInform($$);
sub CommandIOWrite($$);
sub CommandList($$);
sub CommandModify($$);
sub CommandReload($$);
sub CommandRereadCfg($$);
sub CommandRename($$);
sub CommandQuit($$);
sub CommandSave($$);
sub CommandSet($$);
sub CommandSetstate($$);
sub CommandSleep($$);
sub CommandShutdown($$);
sub CommandTrigger($$);

##################################################
# Variables:
# global, to be able to access them from modules

#Special values in %modules (used if set):
# DefFn    - define a "device" of this type
# UndefFn  - clean up at delete
# ParseFn  - Interpret a raw message
# ListFn   - details for this "device"
# SetFn    - set/activate this device
# GetFn    - get some data from this device
# StateFn  - set local info for this device, do not activate anything
# NotifyFn - call this if some device changed its properties
# ReadyFn - check for available data, if no FD
# ReadFn - Reading from a Device (see FHZ/WS300)

#Special values in %defs:
# TYPE    - The name of the module it belongs to
# STATE   - Oneliner describing its state
# NR      - its "serial" number
# DEF     - its definition
# READINGS- The readings. Each value has a "VAL" and a "TIME" component.
# FD      - FileDescriptor. Used by selectlist / readyfnlist
# IODev   - attached to io device
# CHANGED - Currently changed attributes of this device. Used by NotifyFn
# VOLATILE- Set if the definition should be saved to the "statefile"

use vars qw(%modules);		# List of loaded modules (device/log/etc)
use vars qw(%defs);		# FHEM device/button definitions
use vars qw(%attr);		# Attributes
use vars qw(%selectlist);	# devices which want a "select"
use vars qw(%readyfnlist);	# devices which want a "readyfn"
use vars qw($readytimeout);	# Polling interval. UNIX: device search only
$readytimeout = ($^O eq "MSWin32") ? 0.1 : 5.0;

use vars qw(%value);		# Current values, see commandref.html
use vars qw(%oldvalue);		# Old values, see commandref.html
use vars qw($init_done);        #
use vars qw($internal_data);    #
use vars qw(%cmds);             # Global command name hash. To be expanded
use vars qw(%data);		# Hash for user data
use vars qw($devcount);	        # To sort the devices
use vars qw(%defaultattr);    	# Default attributes, used by FHEM2FHEM
use vars qw(%addNotifyCB);	# Used by event enhancers (e.g. avarage)

use vars qw($reread_active);

my $AttrList = "room comment alias";

my $server;			# Server socket
my $ipv6;			# Using IPV6
my $currlogfile;		# logfile, without wildcards
my $logopened = 0;              # logfile opened or using stdout
my %client;			# Client array
my $rcvdquit;			# Used for quit handling in init files
my $sig_term = 0;		# if set to 1, terminate (saving the state)
my %intAt;			# Internal at timer hash.
my $nextat;                     # Time when next timer will be triggered.
my $intAtCnt=0;
my %duplicate;                  # Pool of received msg for multi-fhz/cul setups
my $duplidx=0;                  # helper for the above pool
my $cvsid = '$Id: fhem.pl,v 1.158 2011/10/23 09:23:55 rudolfkoenig Exp $';
my $namedef =
  "where <name> is either:\n" .
  "- a single device name\n" .
  "- a list seperated by komma (,)\n" .
  "- a regexp, if contains one of the following characters: *[]^\$\n" .
  "- a range seperated by dash (-)\n";
my $stt_sec;                    # Used by SecondsTillTomorrow()
my $stt_day;                    # Used by SecondsTillTomorrow()

$init_done = 0;

$modules{Global}{ORDER} = -1;
$modules{Global}{LOADED} = 1;
$modules{Global}{AttrList} =
        "archivecmd allowfrom archivedir configfile lastinclude logfile " .
        "modpath nrarchive pidfilename port statefile title userattr " .
        "verbose:1,2,3,4,5 mseclog version nofork logdir holiday2we " .
        "autoload_undefined_devices dupTimeout latitude longitude  backupdir";
$modules{Global}{AttrFn} = "GlobalAttr";
my $commonAttr = "eventMap";


%cmds = (
  "?"       => { Fn=>"CommandHelp",
	    Hlp=>",get this help" },
  "attr" => { Fn=>"CommandAttr",
           Hlp=>"<devspec> <attrname> [<attrval>],set attribute for <devspec>"},
  "define"  => { Fn=>"CommandDefine",
	    Hlp=>"<name> <type> <options>,define a device/at/notify entity" },
  "deleteattr" => { Fn=>"CommandDeleteAttr",
	    Hlp=>"<devspec> [<attrname>],delete attribute for <devspec>" },
  "delete"  => { Fn=>"CommandDelete",
	    Hlp=>"<devspec>,delete the corresponding definition(s)"},
  "get"     => { Fn=>"CommandGet",
	    Hlp=>"<devspec> <type dependent>,request data from <devspec>" },
  "help"    => { Fn=>"CommandHelp",
	    Hlp=>",get this help" },
  "include" => { Fn=>"CommandInclude",
	    Hlp=>"<filename>,read the commands from <filenname>" },
  "inform" => { Fn=>"CommandInform",
	    Hlp=>"{on|timer|raw|off},echo all events to this client" },
  "iowrite" => { Fn=>"CommandIOWrite",
            Hlp=>"<iodev> <data>,write raw data with iodev" },
  "list"    => { Fn=>"CommandList",
	    Hlp=>"[devspec],list definitions and status info" },
  "modify"  => { Fn=>"CommandModify",
	    Hlp=>"device <options>,modify the definition (e.g. at, notify)" },
  "quit"    => { Fn=>"CommandQuit",
	    Hlp=>",end the client session" },
  "reload"  => { Fn=>"CommandReload",
	    Hlp=>"<module-name>,reload the given module (e.g. 99_PRIV)" },
  "rename"  => { Fn=>"CommandRename",
	    Hlp=>"<old> <new>,rename a definition" },
  "rereadcfg"  => { Fn=>"CommandRereadCfg",
	    Hlp=>",reread the config file" },
  "save"    => { Fn=>"CommandSave",
	    Hlp=>"[configfile],write the configfile and the statefile" },
  "set"     => { Fn=>"CommandSet",
	    Hlp=>"<devspec> <type dependent>,transmit code for <devspec>" },
  "setstate"=> { Fn=>"CommandSetstate",
	    Hlp=>"<devspec> <state>,set the state shown in the command list" },
  "setdefaultattr" => { Fn=>"CommandDefaultAttr",
	    Hlp=>"<attrname> <attrvalue>,set attr for following definitions" },
  "shutdown"=> { Fn=>"CommandShutdown",
	    Hlp=>",terminate the server" },
  "sleep"  => { Fn=>"CommandSleep",
            Hlp=>"<sec>,sleep for sec, 3 decimal places" },
  "trigger" => { Fn=>"CommandTrigger",
            Hlp=>"<devspec> <state>,trigger notify command" },
);

###################################################
# Start the program
if(int(@ARGV) != 1 && int(@ARGV) != 2) {
  print "Usage:\n";
  print "as server: fhem configfile\n";
  print "as client: fhem [host:]port cmd\n";
  CommandHelp(undef, undef);
  exit(1);
}

# If started as root, and there is a fhem user in the /etc/passwd, su to it
if($^O !~ m/Win/ && $< == 0) {

  my @gr = getgrnam("dialout");
  if(@gr) {
    use POSIX qw(setgid);
    setgid($gr[2]);
  }

  my @pw = getpwnam("fhem");
  if(@pw) {
    use POSIX qw(setuid);
    setuid($pw[2]);
  }
}

###################################################
# Client code
if(int(@ARGV) == 2) {
  my $buf;
  my $addr = $ARGV[0];
  $addr = "localhost:$addr" if($ARGV[0] !~ m/:/);
  $server = IO::Socket::INET->new(PeerAddr => $addr);
  die "Can't connect to $addr\n" if(!$server);
  syswrite($server, "$ARGV[1] ; quit\n");
  while(sysread($server, $buf, 256) > 0) {
    print($buf);
  }
  exit(0);
}
# End of client code
###################################################

###################################################
# Server initialization
doGlobalDef($ARGV[0]);

# As newer Linux versions reset serial parameters after fork, we parse the
# config file after the fork. Since need some global attr parameters before, we
# read them here.
setGlobalAttrBeforeFork();   

if($^O =~ m/Win/ && !$attr{global}{nofork}) {
  Log 1, "Forcing 'attr global nofork' on WINDOWS";
  Log 1, "set it in the config file to avoud this message";
  $attr{global}{nofork}=1;
}


# Go to background if the logfile is a real file (not stdout)
if($attr{global}{logfile} ne "-" && !$attr{global}{nofork}) {
  defined(my $pid = fork) || die "Can't fork: $!";
  exit(0) if $pid;
}

# FritzBox special: Wait until the time is set via NTP,
# but not more than 2 hours
while(time() < 2*3600) {
  sleep(5);
}

my $ret = CommandInclude(undef, $attr{global}{configfile});
Log 1, "configfile: $ret" if($ret);
die("No port specified in the configfile.\n") if(!$server);

if($attr{global}{statefile} && -r $attr{global}{statefile}) {
  $ret = CommandInclude(undef, $attr{global}{statefile});
  Log 1, "statefile: $ret" if($ret);
}

SignalHandling();

my $pfn = $attr{global}{pidfilename};
if($pfn) {
  die "$pfn: $!\n" if(!open(PID, ">$pfn"));
  print PID $$ . "\n";
  close(PID);
}

$init_done = 1;
DoTrigger("global", "INITIALIZED");

Log 0, "Server started (version $attr{global}{version}, pid $$)";

################################################
# Main Loop
sub MAIN {MAIN:};               #Dummy


my $errcount= 0;
while (1) {
  my ($rout, $rin) = ('', '');

  my $timeout = HandleTimeout();

  vec($rin, $server->fileno(), 1) = 1;
  foreach my $p (keys %selectlist) {
    vec($rin, $selectlist{$p}{FD}, 1) = 1;
  }
  foreach my $c (keys %client) {
    vec($rin, fileno($client{$c}{fd}), 1) = 1;
  }

  # for documentation see
  # man 2 select
  # http://perldoc.perl.org/functions/select.html
  $timeout = $readytimeout if(keys(%readyfnlist) &&
                              (!defined($timeout) || $timeout > $readytimeout));
  my $nfound = select($rout=$rin, undef, undef, $timeout);

  CommandShutdown(undef, undef) if($sig_term);

  if($nfound < 0) {
    my $err = int($!);
    next if ($err == 0);

    Log 1, "ERROR: Select error $nfound ($err), error count= $errcount";
    $errcount++;

    # Handling "Bad file descriptor". This is a programming error.
    if($err == 9) {  # BADF, don't want to "use errno.ph"
      my $nbad = 0;
      foreach my $p (keys %selectlist) {
        my ($tin, $tout) = ('', '');
        vec($tin, $selectlist{$p}{FD}, 1) = 1;
        if(select($tout=$tin, undef, undef, 0) < 0) {
          Log 1, "Found and deleted bad fileno for $p";
          delete($selectlist{$p});
          $nbad++;
        }
      }
      next if($nbad > 0);
      next if($errcount <= 3);
    }
    die("Select error $nfound ($err)\n");
  } else {
    $errcount= 0;
  }

  ###############################
  # Message from the hardware (FHZ1000/WS3000/etc) via select or the Ready
  # Function. The latter ist needed for Windows, where USB devices are not
  # reported by select, but is used by unix too, to check if the device is
  # attached again.
  foreach my $p (keys %selectlist) {
    next if(!$selectlist{$p});                  # due to rereadcfg / delete
    CallFn($selectlist{$p}{NAME}, "ReadFn", $selectlist{$p})
      if(vec($rout, $selectlist{$p}{FD}, 1));
  }
  foreach my $p (keys %readyfnlist) {
    next if(!$readyfnlist{$p});                 # due to rereadcfg / delete

    if(CallFn($readyfnlist{$p}{NAME}, "ReadyFn", $readyfnlist{$p})) {
      if($readyfnlist{$p}) {                    # delete itself inside ReadyFn
        CallFn($readyfnlist{$p}{NAME}, "ReadFn", $readyfnlist{$p});
      }

    }
  }

  if(vec($rout, $server->fileno(), 1)) {
    my @clientinfo = $server->accept();
    if(!@clientinfo) {
      Log 1, "Accept failed: $!";
      next;
    }
    my ($port, $iaddr) = $ipv6 ?
        sockaddr_in6($clientinfo[1]) :
        sockaddr_in($clientinfo[1]);
    my $caddr = $ipv6 ?
        inet_ntop(AF_INET6(), $iaddr):
        inet_ntoa($iaddr);
    my $af = $attr{global}{allowfrom};
    if($af) {
      if(",$af," !~ m/,$caddr,/) {
        my $hostname = gethostbyaddr($iaddr, AF_INET);
        if(!$hostname || ",$af," !~ m/,$hostname,/) {
          Log 1, "Connection refused from $caddr:$port";
          close($clientinfo[0]);
          next;
        }
      }
    }

    my $fd = $clientinfo[0];
    $client{$fd}{fd}   = $fd;
    $client{$fd}{addr} = "$caddr:$port";
    $client{$fd}{buffer} = "";
    Log 4, "Connection accepted from $client{$fd}{addr}";
  }

  foreach my $c (keys %client) {

    next unless (vec($rout, fileno($client{$c}{fd}), 1));

    my $buf;
    my $ret = sysread($client{$c}{fd}, $buf, 256);
    if(!defined($ret) || $ret <= 0) {
      DoClose($c);
      next;
    }
    if(ord($buf) == 4) {	# EOT / ^D
      CommandQuit($c, "");
      next;
    }
    $buf =~ s/\r//g;
    $client{$c}{buffer} .= $buf;
    AnalyzeInput($c);
  }
}

################################################
#Functions ahead, no more "plain" code

################################################
sub
IsDummy($)
{
  my $devname = shift;

  return 1 if(defined($attr{$devname}) && defined($attr{$devname}{dummy}));
  return 0;
}

sub
IsIgnored($)
{
  my $devname = shift;
  if($devname &&
     defined($attr{$devname}) &&
     defined($attr{$devname}{ignore})) {
    Log 4, "Ignoring $devname";
    return 1;
  }
  return 0;
}


################################################
sub
IsIoDummy($)
{
  my $name = shift;

  return IsDummy($defs{$name}{IODev}{NAME})
                if($defs{$name} && $defs{$name}{IODev});
  return 1;
}


################################################
sub
GetLogLevel(@)
{
  my ($dev,$deflev) = @_;
  my $df = defined($deflev) ? $deflev : 2;

  return $df if(!defined($dev));
  return $attr{$dev}{loglevel}
  	if(defined($attr{$dev}) && defined($attr{$dev}{loglevel}));
  return $df;
}


################################################
sub
Log($$)
{
  my ($loglevel, $text) = @_;

  return if($loglevel > $attr{global}{verbose});

  my @t = localtime;
  my $nfile = ResolveDateWildcards($attr{global}{logfile}, @t);
  OpenLogfile($nfile) if(!$currlogfile || $currlogfile ne $nfile);

  my $tim = sprintf("%04d.%02d.%02d %02d:%02d:%02d",
          $t[5]+1900,$t[4]+1,$t[3], $t[2],$t[1],$t[0]);
  if($attr{global}{mseclog}) {
    my ($seconds, $microseconds) = gettimeofday();
    $tim .= sprintf(".%03d", $microseconds/1000);
  }

  if($logopened) {
    print LOG "$tim $loglevel: $text\n";
  } else {
    print "$tim $loglevel: $text\n";
  }
  return undef;
}


#####################################
sub
DoClose($)
{
  my $c = shift;

  Log 4, "Connection closed for $client{$c}{addr}";
  close($client{$c}{fd});
  delete($client{$c});
  return undef;
}

#####################################
sub
IOWrite($@)
{
  my ($hash, @a) = @_;

  my $dev = $hash->{NAME};
  return if(IsDummy($dev) || IsIgnored($dev));
  my $iohash = $hash->{IODev};
  if(!$iohash ||
     !$iohash->{TYPE} ||
     !$modules{$iohash->{TYPE}} ||
     !$modules{$iohash->{TYPE}}{WriteFn}) {
    Log 5, "No IO device or WriteFn found for $dev";
    return;
  }

  no strict "refs";
  my $ret = &{$modules{$iohash->{TYPE}}{WriteFn}}($iohash, @a);
  use strict "refs";
  return $ret;
}

#####################################
sub
CommandIOWrite($$)
{
  my ($cl, $param) = @_;
  my @a = split(" ", $param);

  return "Usage: iowrite <iodev> <param> ..." if(int(@a) <= 2);

  my $name = shift(@a);
  my $hash = $defs{$name};
  return "$name not found" if(!$hash);
  return undef if(IsDummy($name) || IsIgnored($name));
  if(!$hash->{TYPE} ||
     !$modules{$hash->{TYPE}} ||
     !$modules{$hash->{TYPE}}{WriteFn}) {
    Log 1, "No IO device or WriteFn found for $name";
    return;
  }
  unshift(@a, "") if(int(@a) == 1);
  no strict "refs";
  my $ret = &{$modules{$hash->{TYPE}}{WriteFn}}($hash, @a);
  use strict "refs";
  return $ret;
}


#####################################
sub
AnalyzeInput($)
{
  my $c = shift;
  my @ret;

  while($client{$c}{buffer} =~ m/\n/) {
    my ($cmd, $rest) = split("\n", $client{$c}{buffer}, 2);
    $client{$c}{buffer} = $rest;
    if($cmd) {
      if($cmd =~ m/\\ *$/) {                     # Multi-line
        $client{$c}{prevlines} .= $cmd . "\n";
      } else {
        if($client{$c}{prevlines}) {
          $cmd = $client{$c}{prevlines} . $cmd;
          undef($client{$c}{prevlines});
        }
        my $ret = AnalyzeCommandChain($c, $cmd);
        push @ret, $ret if(defined($ret));
      }
    } else {
      $client{$c}{prompt} = 1;                  # Empty return
    }
    next if($rest);
  }
  my $ret = "";
  $ret .= (join("\n", @ret) . "\n") if(@ret);
  $ret .= ($client{$c}{prevlines} ? "> " : "fhem> ")
          if($client{$c}{prompt} && !$client{$c}{rcvdQuit});
  syswrite($client{$c}{fd}, $ret) if($ret);
  DoClose($c) if($client{$c}{rcvdQuit});
}

#####################################
# i.e. split a line by ; (escape ;;), and execute each
sub
AnalyzeCommandChain($$)
{
  my ($c, $cmd) = @_;
  my @ret;

  $cmd =~ s/#.*$//s;
  $cmd =~ s/;;/SeMiCoLoN/g;
  foreach my $subcmd (split(";", $cmd)) {
    $subcmd =~ s/SeMiCoLoN/;/g;
    my $lret = AnalyzeCommand($c, $subcmd);
    push(@ret, $lret) if(defined($lret));
  }
  return join("\n", @ret) if(@ret);
  return undef;
}

#####################################
sub
AnalyzePerlCommand($$)
{
  my ($cl, $cmd) = @_;

  $cmd =~ s/\\ *\n/ /g;               # Multi-line
  # Make life easier for oneliners:
  %value = ();
  foreach my $d (keys %defs) {
    $value{$d} = $defs{$d}{STATE}
  }
  my ($sec,$min,$hour,$mday,$month,$year,$wday,$yday,$isdst) = localtime;
  my $we = (($wday==0 || $wday==6) ? 1 : 0);
  if(!$we) {
    my $h2we = $attr{global}{holiday2we};
    $we = 1 if($h2we && $value{$h2we} && $value{$h2we} ne "none");
  }
  $month++;
  $year+=1900;
  my $ret = eval $cmd;
  $ret = $@ if($@);
  return $ret;
}

sub
AnalyzeCommand($$)
{
  my ($cl, $cmd) = @_;

  $cmd =~ s/^(\\\n|[ \t])*//;# Strip space or \\n at the begginning
  $cmd =~ s/[ \t]*$//;


  Log 5, "Cmd: >$cmd<";
  return undef if(!$cmd);

  if($cmd =~ m/^{.*}$/s) {		# Perl code
    return AnalyzePerlCommand($cl, $cmd);
  }

  if($cmd =~ m/^"(.*)"$/s) { # Shell code in bg, to be able to call us from it
    my $out = "";
    $out = ">> $currlogfile 2>&1" if($currlogfile ne "-");
    system("$1 $out &");
    return undef;
  }

  $cmd =~ s/^[ \t]*//;
  my ($fn, $param) = split("[ \t][ \t]*", $cmd, 2);
  return undef if(!$fn);

  $fn = "setdefaultattr" if($fn eq "defattr"); # Compatibility mode

  #############
  # Search for abbreviation
  if(!defined($cmds{$fn})) {
    foreach my $f (sort keys %cmds) {
      if(length($f) > length($fn) && substr($f, 0, length($fn)) eq $fn) {
	Log 5, "$fn => $f";
        $fn = $f;
        last;
      }
    }
  }

  return "Unknown command $fn, try help" if(!defined($cmds{$fn}));
  $param = "" if(!defined($param));
  no strict "refs";
  my $ret = &{$cmds{$fn}{Fn} }($cl, $param);
  use strict "refs";
  return undef if(defined($ret) && $ret eq "");
  return $ret;
}

sub
devspec2array($)
{
  my %knownattr = ( "DEF"=>1, "STATE"=>1, "TYPE"=>1 );

  my ($name) = @_;

  return "" if(!defined($name));
  return $name if(defined($defs{$name}));

  my ($isattr, @ret);

  foreach my $l (split(",", $name)) {   # List

    if($l =~ m/(.*)=(.*)/) {
      my ($lattr,$re) = ($1, $2);
      if($knownattr{$lattr}) {
        eval {                          # a bad regexp may shut down fhem.pl
          foreach my $l (sort keys %defs) {
              push @ret, $l
                if($defs{$l}{$lattr} && (!$re || $defs{$l}{$lattr}=~m/^$re$/));
          }
        };
        if($@) {
          Log 1, "devspec2array $name: $@";
          return $name;
        }
      } else {
        foreach my $l (sort keys %attr) {
          push @ret, $l
            if($attr{$l}{$lattr} && (!$re || $attr{$l}{$lattr} =~ m/$re/));
        }
      }
      $isattr = 1;
      next;
    }

    my $regok;
    eval {                              # a bad regexp may shut down fhem.pl
      if($l =~ m/[*\[\]^\$]/) {         # Regexp
        push @ret, grep($_ =~ m/^$l$/, sort keys %defs);
        $regok = 1;
      }
    };
    if($@) {
      Log 1, "devspec2array $name: $@";
      return $name;
    }
    next if($regok);

    if($l =~ m/-/) {                    # Range
      my ($lower, $upper) = split("-", $l, 2);
      push @ret, grep($_ ge $lower && $_ le $upper, sort keys %defs);
      next;
    }
    push @ret, $l;
  }

  return $name if(!@ret && !$isattr);             # No match, return the input
  @ret = grep { !$attr{$_} || !$attr{$_}{ignore} } @ret
        if($name !~ m/^ignore=/);
  return @ret;
}

#####################################
sub
CommandHelp($$)
{
  my ($cl, $param) = @_;

  my $str = "\n" .
            "Possible commands:\n\n" .
            "Command   Parameter                 Description\n" .
	    "-----------------------------------------------\n";

  for my $cmd (sort keys %cmds) {
    my @a = split(",", $cmds{$cmd}{Hlp}, 2);

    $str .= sprintf("%-9s %-25s %s\n", $cmd, $a[0], $a[1]);
  }
  return $str;
}

#####################################
sub
CommandInclude($$)
{
  my ($cl, $arg) = @_;
  my $fh;
  my @ret;

  if(!open($fh, $arg)) {
    return "Can't open $arg: $!";
  }

  my $bigcmd = "";
  $rcvdquit = 0;
  while(my $l = <$fh>) {
    $l =~ s/[\r\n]//g;

    if($l =~ m/^(.*)\\ *$/) {		# Multiline commands
      $bigcmd .= "$1\\\n";
    } else {
      my $tret = AnalyzeCommandChain($cl, $bigcmd . $l);
      push @ret, $tret if(defined($tret));
      $bigcmd = "";
    }
    last if($rcvdquit);

  }
  close($fh);
  return join("\n", @ret) if(@ret);
  return undef;
}


#####################################
sub
OpenLogfile($)
{
  my $param = shift;

  close(LOG);
  $logopened=0;
  $currlogfile = $param;
  if($currlogfile eq "-") {

    open LOG, '>&STDOUT'    or die "Can't dup stdout: $!";

  } else {

    HandleArchiving($defs{global});
    $defs{global}{currentlogfile} = $param;
    $defs{global}{logfile} = $attr{global}{logfile};

    open(LOG, ">>$currlogfile") || return("Can't open $currlogfile: $!");
    redirectStdinStdErr() if($init_done);
    
  }
  LOG->autoflush(1);
  $logopened = 1;
  return undef;
}

sub
redirectStdinStdErr()
{
  # Redirect stdin/stderr
  return if(!$currlogfile || $currlogfile eq "-");

  open STDIN,  '</dev/null'      or print "Can't read /dev/null: $!\n";

  close(STDERR);
  open(STDERR, ">>$currlogfile") or print "Can't append STDERR to log: $!\n";
  STDERR->autoflush(1);

  close(STDOUT);
  open STDOUT, '>&STDERR'        or print "Can't dup stdout: $!\n";
  STDOUT->autoflush(1);
}


#####################################
sub
CommandRereadCfg($$)
{
  my ($cl, $param) = @_;

  WriteStatefile();

  $reread_active=1;

  foreach my $d (keys %defs) {
    my $ret = CallFn($d, "UndefFn", $defs{$d}, $d);
    return $ret if($ret);
  }

  my $cfgfile = $attr{global}{configfile};
  %defs = ();
  %attr = ();
  %selectlist = ();
  %readyfnlist = ();

  doGlobalDef($cfgfile);

  my $ret = CommandInclude($cl, $cfgfile);
  if(!$ret && $attr{global}{statefile} && -r $attr{global}{statefile}) {
    $ret = CommandInclude($cl, $attr{global}{statefile});
  }
  DoTrigger("global", "REREADCFG");

  $reread_active=0;
  return $ret;
}

#####################################
sub
CommandQuit($$)
{
  my ($cl, $param) = @_;

  if(!$cl) {
    $rcvdquit = 1;
  } else {
    $client{$cl}{rcvdQuit} = 1;
    return "Bye..." if($client{$cl}{prompt});
  }
  return undef;
}

#####################################
sub
WriteStatefile()
{
  return if(!$attr{global}{statefile});
  if(!open(SFH, ">$attr{global}{statefile}")) {
    my $msg = "WriteStateFile: Cannot open $attr{global}{statefile}: $!";
    Log 1, $msg;
    return $msg;
  }

  my $t = localtime;
  print SFH "#$t\n";

  foreach my $d (sort keys %defs) {
    next if($defs{$d}{TEMPORARY});
    print SFH "define $d $defs{$d}{TYPE} $defs{$d}{DEF}\n"
        if($defs{$d}{VOLATILE});
    print SFH "setstate $d $defs{$d}{STATE}\n"
        if(defined($defs{$d}{STATE}) &&
           $defs{$d}{STATE} ne "unknown" &&
           $defs{$d}{STATE} ne "Initialized");

    #############
    # Now the detailed list
    my $r = $defs{$d}{READINGS};
    if($r) {
      foreach my $c (sort keys %{$r}) {

	if(!defined($r->{$c}{TIME})) {
	  Log 3, "WriteStatefile $d $c: Missing TIME";
	} elsif(!defined($r->{$c}{VAL})) {
	  Log 3, "WriteStatefile $d $c: Missing VAL";
	} else {
	  print SFH "setstate $d $r->{$c}{TIME} $c $r->{$c}{VAL}\n";
        }

      }
    }
  }

  close(SFH);
}

#####################################
sub
CommandSave($$)
{
  my ($cl, $param) = @_;
  my $ret = WriteStatefile();

  $param = $attr{global}{configfile} if(!$param);
  return "No configfile attribute set and no argument specified" if(!$param);
  if(!open(SFH, ">$param")) {
    return "Cannot open $param: $!";
  }

  foreach my $d (sort { $defs{$a}{NR} <=> $defs{$b}{NR} } keys %defs) {
    next if($defs{$d}{TEMPORARY} || # e.g. WEBPGM connections
            $defs{$d}{VOLATILE});   # e.g at, will be saved to the statefile

    if($d ne "global") {
      if($defs{$d}{DEF}) {
        my $def = $defs{$d}{DEF};
        $def =~ s/;/;;/g;
        print SFH "\ndefine $d $defs{$d}{TYPE} $def\n";
      } else {
        print SFH "\ndefine $d $defs{$d}{TYPE}\n";
      }
    }
    foreach my $a (sort keys %{$attr{$d}}) {
      next if($d eq "global" &&
              ($a eq "configfile" || $a eq "version"));
      print SFH "attr $d $a $attr{$d}{$a}\n";
    }
  }
  print SFH "include $attr{global}{lastinclude}\n"
        if($attr{global}{lastinclude});


  close(SFH);
  return undef;
}

#####################################
sub
CommandShutdown($$)
{
  my ($cl, $param) = @_;
  DoTrigger("global", "SHUTDOWN");
  Log 0, "Server shutdown";

  foreach my $d (sort keys %defs) {
    CallFn($d, "ShutdownFn", $defs{$d});
  }

  WriteStatefile();
  unlink($attr{global}{pidfilename}) if($attr{global}{pidfilename});
  exit(0);
}

#####################################
sub
DoSet(@)
{
  my @a = @_;

  my $dev = $a[0];
  return "Please define $dev first" if(!$defs{$dev});
  return "No set implemented for $dev" if(!$modules{$defs{$dev}{TYPE}}{SetFn});

  @a = ReplaceEventMap($dev, \@a, 0) if($attr{$dev}{eventMap});
  my $ret = CallFn($dev, "SetFn", $defs{$dev}, @a);
  return $ret if($ret);

  shift @a;
  return DoTrigger($dev, join(" ", @a));
}


#####################################
sub
CommandSet($$)
{
  my ($cl, $param) = @_;
  my @a = split("[ \t][ \t]*", $param);
  return "Usage: set <name> <type-dependent-options>\n$namedef" if(int(@a)<1);

  my @rets;
  foreach my $sdev (devspec2array($a[0])) {

    $a[0] = $sdev;
    my $ret = DoSet(@a);
    push @rets, $ret if($ret);

  }
  return join("\n", @rets);
}


#####################################
sub
CommandGet($$)
{
  my ($cl, $param) = @_;

  my @a = split("[ \t][ \t]*", $param);
  return "Usage: get <name> <type-dependent-options>\n$namedef" if(int(@a) < 1);


  my @rets;
  foreach my $sdev (devspec2array($a[0])) {
    if(!defined($defs{$sdev})) {
      push @rets, "Please define $sdev first";
      next;
    }
    if(!$modules{$defs{$sdev}{TYPE}}{GetFn}) {
      push @rets, "No get implemented for $sdev";
      next;
    }

    $a[0] = $sdev;
    my $ret = CallFn($sdev, "GetFn", $defs{$sdev}, @a);
    push @rets, $ret if($ret);
  }
  return join("\n", @rets);
}

#####################################
sub
LoadModule($)
{
  my ($m) = @_;

  if($modules{$m} && !$modules{$m}{LOADED}) {   # autoload
    my $o = $modules{$m}{ORDER};
    my $ret = CommandReload(undef, "${o}_$m");
    if($ret) {
      Log 0, $ret;
      return "UNDEFINED";
    }

    if(!$modules{$m}{LOADED}) {                 # Case corrected by reload?
      foreach my $i (keys %modules) {
        if(uc($m) eq uc($i) && $modules{$i}{LOADED}) {
          delete($modules{$m});
          $m = $i;
          last;
        }
      }
    }
  }
  return $m;
}

#####################################
sub
CommandDefine($$)
{
  my ($cl, $def) = @_;
  my @a = split("[ \t][ \t]*", $def, 3);

  return "Usage: define <name> <type> <type dependent arguments>"
  					if(int(@a) < 2);
  return "$a[0] already defined, delete it first" if(defined($defs{$a[0]}));
  return "Invalid characters in name (not A-Za-z0-9.:_): $a[0]"
                        if($a[0] !~ m/^[a-z0-9.:_]*$/i);

  my $m = $a[1];
  if(!$modules{$m}) {                           # Perhaps just wrong case?
    foreach my $i (keys %modules) {
      if(uc($m) eq uc($i)) {
        $m = $i;
        last;
      }
    }
  }

  $m = LoadModule($m);

  if(!$modules{$m} || !$modules{$m}{DefFn}) {
    my @m = grep { $modules{$_}{DefFn} || !$modules{$_}{LOADED} }
                sort keys %modules;
    return "Unknown module $m, choose one of @m";
  }

  my %hash;

  $hash{NAME}  = $a[0];
  $hash{TYPE}  = $m;
  $hash{STATE} = "???";
  $hash{DEF}   = $a[2] if(int(@a) > 2);
  $hash{NR}    = $devcount++;

  # If the device wants to issue initialization gets/sets, then it needs to be
  # in the global hash.
  $defs{$a[0]} = \%hash;

  my $ret = CallFn($a[0], "DefFn", \%hash, $def);
  if($ret) {
    Log 1, "define: $ret";
    delete $defs{$a[0]};                            # Veto
    delete $attr{$a[0]};

  } else {
    foreach my $da (sort keys (%defaultattr)) {     # Default attributes
      CommandAttr($cl, "$a[0] $da $defaultattr{$da}");
    }
    DoTrigger("global", "DEFINED $a[0]");

  }
  return $ret;
}

#####################################
sub
CommandModify($$)
{
  my ($cl, $def) = @_;
  my @a = split("[ \t]+", $def, 2);

  return "Usage: modify <name> <type dependent arguments>"
  					if(int(@a) < 2);

  # Return a list of modules
  return "Define $a[0] first" if(!defined($defs{$a[0]}));
  my $hash = $defs{$a[0]};

  $hash->{OLDDEF} = $hash->{DEF};
  $hash->{DEF} = $a[1];
  my $ret = CallFn($a[0], "DefFn", $hash, "$a[0] $hash->{TYPE} $a[1]");
  $hash->{DEF} = $hash->{OLDDEF} if($ret);
  delete($hash->{OLDDEF});
  return $ret;
}

#############
# internal
sub
AssignIoPort($)
{
  my ($hash) = @_;

  # Set the I/O device, search for the last compatible one.
  for my $p (sort { $defs{$b}{NR} <=> $defs{$a}{NR} } keys %defs) {

    my $cl = $defs{$p}{Clients};
    $cl = $modules{$defs{$p}{TYPE}}{Clients} if(!$cl);

    if((defined($cl) && $cl =~ m/:$hash->{TYPE}:/) &&
        $defs{$p}{NAME} ne $hash->{NAME}) {      # e.g. RFR
      $hash->{IODev} = $defs{$p};
      last;
    }
  }
  Log 3, "No I/O device found for $hash->{NAME}" if(!$hash->{IODev});
}


#############
sub
CommandDelete($$)
{
  my ($cl, $def) = @_;
  return "Usage: delete <name>$namedef\n" if(!$def);

  my @rets;
  foreach my $sdev (devspec2array($def)) {
    if(!defined($defs{$sdev})) {
      push @rets, "Please define $sdev first";
      next;
    }

    my $ret = CallFn($sdev, "UndefFn", $defs{$sdev}, $sdev);
    if($ret) {
      push @rets, $ret;
      next;
    }

    # Delete releated hashes
    foreach my $p (keys %selectlist) {
      if($selectlist{$p} && $selectlist{$p}{NAME} eq $sdev) {
        delete $selectlist{$p};
      }
    }
    foreach my $p (keys %readyfnlist) {
      delete $readyfnlist{$p}
        if($readyfnlist{$p} && $readyfnlist{$p}{NAME} eq $sdev);
    }

    delete($attr{$sdev});
    my $temporary = $defs{$sdev}{TEMPORARY};
    delete($defs{$sdev});       # Remove the main entry
    DoTrigger("global", "DELETED $sdev") if(!$temporary);

  }
  return join("\n", @rets);
}

#############
sub
CommandDeleteAttr($$)
{
  my ($cl, $def) = @_;

  my @a = split(" ", $def, 2);
  return "Usage: deleteattr <name> [<attrname>]\n$namedef" if(@a < 1);

  my @rets;
  foreach my $sdev (devspec2array($a[0])) {

    if($sdev eq "global") {
      push @rets, "Cannot delete global parameters";
      next;
    }
    if(!defined($defs{$sdev})) {
      push @rets, "Please define $sdev first";
      next;
    }

    $a[0] = $sdev;
    $ret = CallFn($sdev, "AttrFn", "del", @a);
    if($ret) {
      push @rets, $ret;
      next;
    }

    if(@a == 1) {
      delete($attr{$sdev});
    } else {
      delete($attr{$sdev}{$a[1]}) if(defined($attr{$sdev}));
    }

  }

  return join("\n", @rets);
}

sub
PrintHash($$)
{
  my ($h, $lev) = @_;

  my ($str,$sstr) = ("","");
  foreach my $c (sort keys %{$h}) {

    if(ref($h->{$c})) {
      if(ref($h->{$c}) eq "HASH") {
        if(defined($h->{$c}{TIME}) && defined($h->{$c}{VAL})) {
          $str .= sprintf("%*s %-19s   %-15s %s\n",
                          $lev," ", $h->{$c}{TIME},$c,$h->{$c}{VAL});
        } elsif($c eq "IODev" || $c eq "HASH") {
          $str .= sprintf("%*s %-10s %s\n", $lev," ",$c, $h->{$c}{NAME});
        } else {
          $sstr .= sprintf("%*s %s:\n",
                          $lev, " ", uc(substr($c,0,1)).lc(substr($c,1)));
          $sstr .= PrintHash($h->{$c}, $lev+2);
        }
      }
    } else {
      $str .= sprintf("%*s %-10s %s\n", $lev," ",$c, $h->{$c});
    }
  }
  return $str . $sstr;
}

#####################################
sub
CommandList($$)
{
  my ($cl, $param) = @_;
  my $str = "";

  if(!$param) {

    $str = "\nType list <name> for detailed info.\n";
    my $lt = "";

    # Sort first by type then by name
    for my $d (sort { my $x=$modules{$defs{$a}{TYPE}}{ORDER}.$defs{$a}{TYPE} cmp
		  	    $modules{$defs{$b}{TYPE}}{ORDER}.$defs{$b}{TYPE};
		         $x=($a cmp $b) if($x == 0); $x; } keys %defs) {
      next if(IsIgnored($d));
      my $t = $defs{$d}{TYPE};
      $str .= "\n$t:\n" if($t ne $lt);
      $str .= sprintf("  %-20s (%s)\n", $d, $defs{$d}{STATE});
      $lt = $t;
    }

  } else {

    my @arg = split(" ", $param);
    my @list = devspec2array($arg[0]);
    if($arg[1]) {
      foreach my $sdev (@list) {

        if($defs{$sdev} &&
           $defs{$sdev}{$arg[1]}) {
          $str .= $sdev . " " .
                  $defs{$sdev}{$arg[1]} . "\n";

        } elsif($defs{$sdev} &&
           $defs{$sdev}{READINGS} &&
           $defs{$sdev}{READINGS}{$arg[1]}) {
          $str .= $sdev . " ".
                  $defs{$sdev}{READINGS}{$arg[1]}{TIME} . " " .
                  $defs{$sdev}{READINGS}{$arg[1]}{VAL} . "\n";
        }
      }

    } elsif(@list == 1) {
      my $sdev = $list[0];
      if(!defined($defs{$sdev})) {
        $str .= "No device named $param found";
      } else {
        $str .= "Internals:\n";
        $str .= PrintHash($defs{$sdev}, 2);
        $str .= "Attributes:\n";
        $str .= PrintHash($attr{$sdev}, 2);
      }

    } else {
      foreach my $sdev (@list) {
        $str .= "$sdev\n";
      }

    }
  }

  return $str;
}


#####################################
sub
CommandReload($$)
{
  my ($cl, $param) = @_;
  my %hash;
  $param =~ s,/,,g;
  $param =~ s,\.pm$,,g;
  my $file = "$attr{global}{modpath}/FHEM/$param.pm";
  return "Can't read $file: $!" if(! -r "$file");

  my $m = $param;
  $m =~ s,^([0-9][0-9])_,,;
  my $order = (defined($1) ? $1 : "00");
  Log 5, "Loading $file";

  no strict "refs";
  eval {
    my $ret=do "$file";
    if(!$ret) {
      Log 1, "reload: Error:Modul $param deactivated:\n $@";
      use strict "refs";
      return "$@";
    }

    # Get the name of the initialize function. This may differ from the
    # filename as sometimes we live on a FAT fs with wrong case.
    my $fnname = $m;
    foreach my $i (keys %main::) {
      if($i =~ m/^(${m})_initialize$/i) {
        $fnname = $1;
        last;
      }
    }
    $ret = &{ "${fnname}_Initialize" }(\%hash);
    $m = $fnname;
  };
  use strict "refs";

  return "$@" if($@);

  my ($defptr, $ldata);
  if($modules{$m}) {
    $defptr = $modules{$m}{defptr};
    $ldata = $modules{$m}{ldata};
  }
  $modules{$m} = \%hash;
  $modules{$m}{ORDER} = $order;
  $modules{$m}{LOADED} = 1;
  $modules{$m}{defptr} = $defptr if($defptr);
  $modules{$m}{ldata} = $defptr if($ldata);

  return undef;
}

#####################################
sub
CommandRename($$)
{
  my ($cl, $param) = @_;
  my ($old, $new) = split(" ", $param);

  return "Please define $old first" if(!defined($defs{$old}));
  return "Invalid characters in name (not A-Za-z0-9.:_): $new"
                        if($new !~ m/^[a-z0-9.:_]*$/i);
  return "Cannot rename global" if($old eq "global");

  $defs{$new} = $defs{$old};
  $defs{$new}{NAME} = $new;
  delete($defs{$old});          # The new pointer will preserve the hash

  $attr{$new} = $attr{$old} if(defined($attr{$old}));
  delete($attr{$old});

  $oldvalue{$new} = $oldvalue{$old} if(defined($oldvalue{$old}));
  delete($oldvalue{$old});

  DoTrigger("global", "RENAMED $old $new");
  return undef;
}

#####################################
sub
getAllAttr($)
{
  my $d = shift;
  return "" if(!$defs{$d});

  my $list = $AttrList;
  $list .= " " . $modules{$defs{$d}{TYPE}}{AttrList}
        if($modules{$defs{$d}{TYPE}}{AttrList});
  $list .= " " . $attr{global}{userattr}
        if($attr{global}{userattr});
  $list .= " " . $commonAttr;
  return $list;
}

#####################################
sub
getAllSets($)
{
  my $d = shift;
  my $a2 = CommandSet(undef, "$d ?");
  $a2 =~ s/.*choose one of //;
  $a2 = "" if($a2 =~ /^No set implemented for/);
  return $a2;
}

sub
GlobalAttr($$)
{
  my ($type, $me, $name, $val) = @_;

  return if($type ne "set");
  ################
  if($name eq "logfile") {
    my @t = localtime;
    my $ret = OpenLogfile(ResolveDateWildcards($val, @t));
    if($ret) {
      return $ret if($init_done);
      die($ret);
    }
  }

  ################
  elsif($name eq "port") {

    return undef if($reread_active);
    my ($port, $global) = split(" ", $val);
    if($global && $global ne "global") {
      return "Bad syntax, usage: attr global port <portnumber> [global]";
    }
    if($port =~ m/^IPV6:(\d+)$/i) {
      $port = $1;
      $ipv6 = 1;
      eval "require IO::Socket::INET6; use Socket6;";
      if($@) {
        Log 1, "attr global port: $@";
        Log 1, "Can't load INET6, falling back to IPV4";
        $ipv6 = 0;
      }
    }

    my $server2;
    my @opts = (
        Domain    => ($ipv6 ? AF_INET6() : AF_UNSPEC), # Linux bug
        LocalHost => ($global ? undef : "localhost"),
        LocalPort => $port,
        Listen    => 10,
        ReuseAddr => 1
    );
    $server2 = $ipv6 ? IO::Socket::INET6->new(@opts) : 
                       IO::Socket::INET->new(@opts);
    if(!$server2) {
      Log 1, "attr global port: Can't open server port at $port: $!";
      return "$!" if($init_done);
      die "Can't open server port at $port: $!\n";
    }
    close($server) if($server);
    $server = $server2;
  }

  ################
  elsif($name eq "verbose") {
    if($val =~ m/^[0-5]$/) {
      return undef;
    } else {
      $attr{global}{verbose} = 3;
      return "Valid value for verbose are 0,1,2,3,4,5";
    }
  }

  elsif($name eq "modpath") {
    return "modpath must point to a directory where the FHEM subdir is"
        if(! -d "$val/FHEM");
    my $modpath = "$val/FHEM";

    opendir(DH, $modpath) || return "Can't read $modpath: $!";
    my $counter = 0;

    foreach my $m (sort readdir(DH)) {
      next if($m !~ m/^([0-9][0-9])_(.*)\.pm$/);
      $modules{$2}{ORDER} = $1;
      CommandReload(undef, $m)                  # Always load utility modules
         if($1 eq "99" && !$modules{$2}{LOADED});
      $counter++;
    }
    closedir(DH);

    if(!$counter) {
      return "No modules found, set modpath to a directory in which a " .
             "subdirectory called \"FHEM\" exists wich in turn contains " .
             "the fhem module files <*>.pm";
    }

  }

  return undef;
}

#####################################
sub
CommandAttr($$)
{
  my ($cl, $param) = @_;
  my $ret = undef;
  my @a;

  @a = split(" ", $param, 3) if($param);

  return "Usage: attr <name> <attrname> [<attrvalue>]\n$namedef"
           if(@a && @a < 2);

  my @rets;
  foreach my $sdev (devspec2array($a[0])) {

    if(!defined($defs{$sdev})) {
      push @rets, "Please define $sdev first";
      next;
    }

    my $list = getAllAttr($sdev);
    if($a[1] eq "?") {
      push @rets, "Unknown attribute $a[1], choose one of $list";
      next;
    }

    if(" $list " !~ m/ ${a[1]}[ :;]/) {
       my $found = 0;
       foreach my $atr (split("[ \t]", $list)) { # is it a regexp?
         if(${a[1]} =~ m/^$atr$/) {
           $found++;
           last;
         }
      }
      if(!$found) {
        push @rets, "Unknown attribute $a[1], use attr global userattr $a[1]";
        next;
      }
    }

    if($a[1] eq "IODev" && (!$a[2] || !defined($defs{$a[2]}))) {
      push @rets,"Unknown IODev specified";
      next;
    }

    $a[0] = $sdev;
    $ret = CallFn($sdev, "AttrFn", "set", @a);
    if($ret) {
      push @rets, $ret;
      next;
    }

    if(defined($a[2])) {
      $attr{$sdev}{$a[1]} = $a[2];
    } else {
      $attr{$sdev}{$a[1]} = "1";
    }
    if($a[1] eq "IODev") {
      my $ioname = $a[2];
      $defs{$sdev}{IODev} = $defs{$ioname};
      $defs{$sdev}{NR} = $devcount++
        if($defs{$ioname}{NR} > $defs{$sdev}{NR});
    }
  }
  Log 3, join(" ", @rets) if(!$cl && @rets);
  return join("\n", @rets);
}


#####################################
# Default Attr
sub
CommandDefaultAttr($$)
{
  my ($cl, $param) = @_;

  my @a = split(" ", $param, 2);
  if(int(@a) == 0) {
    %defaultattr = ();
  } elsif(int(@a) == 1) {
    $defaultattr{$a[0]} = 1;
  } else {
    $defaultattr{$a[0]} = $a[1];
  }
  return undef;
}

#####################################
sub
CommandSetstate($$)
{
  my ($cl, $param) = @_;

  my @a = split(" ", $param, 2);
  return "Usage: setstate <name> <state>\n$namedef" if(@a != 2);


  my @rets;
  foreach my $sdev (devspec2array($a[0])) {
    if(!defined($defs{$sdev})) {
      push @rets, "Please define $sdev first";
      next;
    }

    my $d = $defs{$sdev};

    # Detailed state with timestamp
    if($a[1] =~ m/^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) +([^ ].*)$/) {
      my ($tim, $nameval) =  ($1, $2);
      my ($sname, $sval) = split(" ", $nameval, 2);
      my $ret = CallFn($sdev, "StateFn", $d, $tim, $sname, $sval);
      if($ret) {
        push @rets, $ret;
        next;
      }

      if(!$d->{READINGS}{$sname} || $d->{READINGS}{$sname}{TIME} lt $tim) {
        $d->{READINGS}{$sname}{VAL} = $sval;
        $d->{READINGS}{$sname}{TIME} = $tim;
      }

    } else {

      # Do not overwrite state like "opened" or "initialized"
      $d->{STATE} = $a[1] if($init_done || $d->{STATE} eq "???");

      # This time is not the correct one, but we do not store a timestamp for
      # this reading.
      $oldvalue{$sdev}{TIME} = TimeNow();
      $oldvalue{$sdev}{VAL} = $d->{STATE};

    }
  }
  return join("\n", @rets);
}

#####################################
sub
CommandTrigger($$)
{
  my ($cl, $param) = @_;

  my ($dev, $state) = split(" ", $param, 2);
  return "Usage: trigger <name> <state>\n$namedef" if(!$dev);
  $state = "" if(!$state);

  my @rets;
  foreach my $sdev (devspec2array($dev)) {
    if(!defined($defs{$sdev})) {
      push @rets, "Please define $sdev first";
      next;
    }
    my $ret = DoTrigger($sdev, $state);
    if($ret) {
      push @rets, $ret;
      next;
    }
  }
  return join("\n", @rets);
}

#####################################
sub
CommandInform($$)
{
  my ($cl, $param) = @_;

  if(!$cl) {
    return;
  }

  $param = lc($param);

  return "Usage: inform {on|timer|raw|off}"
        if($param !~ m/^(on|off|raw|timer)$/);
  if($param =~ m/off/) {
    delete($client{$cl}{inform});
  } else {
    $client{$cl}{inform} = $param;
    Log 4, "Setting inform to $param";
  }

  return undef;
}

#####################################
sub
CommandSleep($$)
{
  my ($cl, $param) = @_;

  return "Cannot interpret $param as seconds" if($param !~ m/^[0-9\.]+$/);
  Log 4, "sleeping for $param";
  select(undef, undef, undef, $param);
  return undef;
}


#####################################
# Return the time to the next event (or undef if there is none)
# and call each function which was scheduled for this time
sub
HandleTimeout()
{
  return undef if(!$nextat);

  my $now = gettimeofday();
  return ($nextat-$now) if($now < $nextat);

  $nextat = 0;
  #############
  # Check the internal list.
  foreach my $i (sort { $intAt{$a}{TRIGGERTIME} <=>
                        $intAt{$b}{TRIGGERTIME} } keys %intAt) {
    my $tim = $intAt{$i}{TRIGGERTIME};
    my $fn = $intAt{$i}{FN};
    if(!defined($tim) || !defined($fn)) {
      delete($intAt{$i});
      next;
    } elsif($tim <= $now) {
      no strict "refs";
      &{$fn}($intAt{$i}{ARG});
      use strict "refs";
      delete($intAt{$i});
    }
    $nextat = $tim if(!$nextat || $nextat > $tim);
  }

  return undef if(!$nextat);
  $now = gettimeofday();
  return ($now < $nextat) ? ($nextat-$now) : 0;
}


#####################################
sub
InternalTimer($$$$)
{
  my ($tim, $fn, $arg, $waitIfInitNotDone) = @_;

  if(!$init_done && $waitIfInitNotDone) {
    select(undef, undef, undef, $tim-gettimeofday());
    no strict "refs";
    &{$fn}($arg);
    use strict "refs";
    return;
  }
  $intAt{$intAtCnt}{TRIGGERTIME} = $tim;
  $intAt{$intAtCnt}{FN} = $fn;
  $intAt{$intAtCnt}{ARG} = $arg;
  $intAtCnt++;
  $nextat = $tim if(!$nextat || $nextat > $tim);
}

#####################################
sub
RemoveInternalTimer($)
{
  my ($arg) = @_;
  foreach my $a (keys %intAt) {
    delete($intAt{$a}) if($intAt{$a}{ARG} eq $arg);
  }
}


#####################################
sub
SignalHandling()
{
  if($^O ne "MSWin32") {
    $SIG{'INT'}  = sub { $sig_term = 1; };
    $SIG{'TERM'} = sub { $sig_term = 1; };
    $SIG{'PIPE'} = 'IGNORE';
    $SIG{'CHLD'} = 'IGNORE';
    $SIG{'HUP'}  = sub { CommandRereadCfg(undef, "") };

  }
}

#####################################
sub
TimeNow()
{
  my @t = localtime;
  return sprintf("%04d-%02d-%02d %02d:%02d:%02d",
      $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
}

#####################################
sub
FmtDateTime($)
{
  my @t = localtime(shift);
  return sprintf("%04d-%02d-%02d %02d:%02d:%02d",
      $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
}

sub
FmtTime($)
{
  my @t = localtime(shift);
  return sprintf("%02d:%02d:%02d", $t[2], $t[1], $t[0]);
}

#####################################
sub
CommandChain($$)
{
  my ($retry, $list) = @_;
  my $ov = $attr{global}{verbose};
  my $oid = $init_done;

  $init_done = 0;
  $attr{global}{verbose} = 1;
  foreach my $cmd (@{$list}) {
    for(my $n = 0; $n < $retry; $n++) {
      Log 1, sprintf("Trying again $cmd (%d out of %d)", $n+1,$retry) if($n>0);
      my $ret = AnalyzeCommand(undef, $cmd);
      last if(!defined($ret) || $ret !~ m/Timeout/);
    }
  }
  $attr{global}{verbose} = $ov;
  $init_done = $oid;
}

#####################################
sub
ResolveDateWildcards($@)
{
  my ($f, @t) = @_;
  return $f if(!$f);
  return $f if($f !~ m/%/);	# Be fast if there is no wildcard

  my $S = sprintf("%02d", $t[0]);      $f =~ s/%S/$S/g;
  my $M = sprintf("%02d", $t[1]);      $f =~ s/%M/$M/g;
  my $H = sprintf("%02d", $t[2]);      $f =~ s/%H/$H/g;
  my $d = sprintf("%02d", $t[3]);      $f =~ s/%d/$d/g;
  my $m = sprintf("%02d", $t[4]+1);    $f =~ s/%m/$m/g;
  my $Y = sprintf("%04d", $t[5]+1900); $f =~ s/%Y/$Y/g;
  my $w = sprintf("%d",   $t[6]);      $f =~ s/%w/$w/g;
  my $j = sprintf("%03d", $t[7]+1);    $f =~ s/%j/$j/g;
  my $U = sprintf("%02d", int(($t[7]-$t[6]+6)/7));   $f =~ s/%U/$U/g;
  my $V = sprintf("%02d", int(($t[7]-$t[6]+7)/7)+1); $f =~ s/%V/$V/g;
  $f =~ s/%ld/$attr{global}{logdir}/g if($attr{global}{logdir}); #log directory

  return $f;
}

sub
SemicolonEscape($)
{
  my $cmd = shift;
  $cmd =~ s/^[ \t]*//;
  $cmd =~ s/[ \t]*$//;
  if($cmd =~ m/^{.*}$/s || $cmd =~ m/^".*"$/s) {
    $cmd =~ s/;/;;/g
  }
  return $cmd;
}

sub
EvalSpecials($%)
{
     # The character % will be replaced with the received event,
     #     e.g. with on or off or measured-temp: 21.7 (Celsius)
     # The character @ will be replaced with the device name.
     # To use % or @ in the text itself, use the double mode (%% or @@).
     # Instead of % and @, the parameters %EVENT (same as %),
     #     %NAME (same as @) and %TYPE (contains the device type, e.g. FHT)
     #     can be used. A single % looses its special meaning if any of these
     #     parameters appears in the definition.

      my ($exec, %specials)= @_;
      $exec = SemicolonEscape($exec);

      $exec =~ s/%%/____/g;

      # %EVTPART due to HM remote logic
      my $idx = 0;
      foreach my $part (split(" ", $specials{"%EVENT"})) {
        $specials{"%EVTPART$idx"} = $part;
        $idx++;
      }

      # perform macro substitution
      my $extsyntax= 0;
      foreach my $special (keys %specials) {
        $extsyntax+= ($exec =~ s/$special/$specials{$special}/g);
      }
      if(!$extsyntax) {
        $exec =~ s/%/$specials{"%EVENT"}/g;
      }
      $exec =~ s/____/%/g;

      $exec =~ s/@@/____/g;
      $exec =~ s/@/$specials{"%NAME"}/g;
      $exec =~ s/____/@/g;

      return $exec;
}

#####################################
# Parse a timespec: Either HH:MM:SS or HH:MM or { perfunc() }
sub
GetTimeSpec($)
{
  my ($tspec) = @_;
  my ($hr, $min, $sec, $fn);

  if($tspec =~ m/^([0-9]+):([0-5][0-9]):([0-5][0-9])$/) {
    ($hr, $min, $sec) = ($1, $2, $3);
  } elsif($tspec =~ m/^([0-9]+):([0-5][0-9])$/) {
    ($hr, $min, $sec) = ($1, $2, 0);
  } elsif($tspec =~ m/^{(.*)}$/) {
    $fn = $1;
    $tspec = AnalyzeCommand(undef, "{$fn}");
    if(!$@ && $tspec =~ m/^([0-9]+):([0-5][0-9]):([0-5][0-9])$/) {
      ($hr, $min, $sec) = ($1, $2, $3);
    } elsif(!$@ && $tspec =~ m/^([0-9]+):([0-5][0-9])$/) {
      ($hr, $min, $sec) = ($1, $2, 0);
    } else {
      $tspec = "<empty string>" if(!$tspec);
      return ("the at function \"$fn\" must return a timespec and not $tspec.",
      		undef, undef, undef, undef);
    }
  } else {
    return ("Wrong timespec $tspec: either HH:MM:SS or {perlcode}",
    		undef, undef, undef, undef);
  }
  return (undef, $hr, $min, $sec, $fn);
}


#####################################
# Do the notification
sub
DoTrigger($$)
{
  my ($dev, $ns) = @_;
  my $ret = "";

  return "" if(!defined($defs{$dev}));

  if(defined($ns)) {
    $defs{$dev}{CHANGED}[0] = $ns;
  } elsif(!defined($defs{$dev}{CHANGED})) {
    return "";
  }

  if($attr{$dev}{eventMap}) {
    my $c = $defs{$dev}{CHANGED};
    for(my $i = 0; $i < @{$c}; $i++) {
      $c->[$i] = ReplaceEventMap($dev, $c->[$i], 1);
    }
    $defs{$dev}{STATE} = ReplaceEventMap($dev, $defs{$dev}{STATE}, 1);
  }

  # STATE && {READINGS}{state} should be the same
  my $r = $defs{$dev}{READINGS};
  $r->{state}{VAL} = $defs{$dev}{STATE} if($r && $r->{state});

  my $max = int(@{$defs{$dev}{CHANGED}});
  Log 5, "Triggering $dev ($max changes)";
  return "" if(defined($attr{$dev}) && defined($attr{$dev}{do_not_notify}));

  ################
  # Inform
  foreach my $c (keys %client) {        # Do client loop first, is cheaper
    next if(!$client{$c}{inform} || $client{$c}{inform} eq "raw");
    my $tn = TimeNow();
    if($attr{global}{mseclog}) {
      my ($seconds, $microseconds) = gettimeofday();
      $tn .= sprintf(".%03d", $microseconds/1000);
    }
    for(my $i = 0; $i < $max; $i++) {
      my $state = $defs{$dev}{CHANGED}[$i];
      syswrite($client{$c}{fd},
        ($client{$c}{inform} eq "timer" ? "$tn " : "") .
        "$defs{$dev}{TYPE} $dev $state\n");
    }
  }

  ################
  # Log/notify modules
  # If modifying a device in its own trigger, do not call the triggers from
  # the inner loop.
  if(!defined($defs{$dev}{INTRIGGER})) {
    $defs{$dev}{INTRIGGER}=1;
    foreach my $n (sort keys %defs) {
      next if(!defined($defs{$n}));     # Was deleted in a previous notify
      if(defined($modules{$defs{$n}{TYPE}})) {
        if($modules{$defs{$n}{TYPE}}{NotifyFn}) {
          Log 5, "$dev trigger: Checking $n for notify";
          my $r = CallFn($n, "NotifyFn", $defs{$n}, $defs{$dev});
          $ret .= $r if($r);
        }
      }
    }
    delete($defs{$dev}{INTRIGGER});
  }

  ####################
  # Used by triggered perl programs to check the old value
  # Not suited for multi-valued devices (KS300, etc)
  $oldvalue{$dev}{TIME} = TimeNow();
  $oldvalue{$dev}{VAL} = $defs{$dev}{STATE};

  delete($defs{$dev}{CHANGED}) if(!defined($defs{$dev}{INTRIGGER}));

  Log 3, "NTFY return: $ret" if($ret);

  # Enhancers like avarage need this
  if(!defined($defs{$dev}{InNtfyCb}) && %addNotifyCB) {
    $defs{$dev}{InNtfyCb}=1;
    foreach my $cb (keys %addNotifyCB) {
      my ($fn, $arg) = split(" ", $addNotifyCB{$cb}, 2);
      delete $addNotifyCB{$cb};
      no strict "refs";
      &{$fn}($arg);
      use strict "refs";
    } 
    delete($defs{$dev}{CHANGED});
    delete($defs{$dev}{InNtfyCb});
  }

  return $ret;
}

#####################################
# Wrapper for calling a module function
sub
CallFn(@)
{
  my $d = shift;
  my $n = shift;

  if(!$defs{$d}) {
    Log 0, "Strange call for nonexistent $d: $n";
    return undef;
  }
  if(!$defs{$d}{TYPE}) {
    Log 0, "Strange call for typeless $d: $n";
    return undef;
  }
  my $fn = $modules{$defs{$d}{TYPE}}{$n};
  return "" if(!$fn);
  no strict "refs";
  my $ret = &{$fn}(@_);
  use strict "refs";
  return $ret;
}

#####################################
# Used from perl oneliners inside of scripts
sub
fhem($)
{
  my $param = shift;
  my $ret = AnalyzeCommandChain(undef, $param);
  Log 3, "$param : $ret" if($ret);
  return $ret;
}

#####################################
# initialize the global device
sub
doGlobalDef($)
{
  my ($arg) = @_;

  $devcount = 1;
  $defs{global}{NR}    = $devcount++;
  $defs{global}{TYPE}  = "Global";
  $defs{global}{STATE} = "<no definition>";
  $defs{global}{DEF}   = "<no definition>";
  $defs{global}{NAME}  = "global";

  CommandAttr(undef, "global verbose 3");
  CommandAttr(undef, "global configfile $arg");
  CommandAttr(undef, "global logfile -");
  CommandAttr(undef, "global version =VERS= from =DATE= ($cvsid)");
}

#####################################
# rename does not work over Filesystems: lets copy it
sub
myrename($$)
{
  my ($from, $to) = @_;

  if(!open(F, $from)) {
    Log(1, "Rename: Cannot open $from: $!");
    return;
  }
  if(!open(T, ">$to")) {
    Log(1, "Rename: Cannot open $to: $!");
    return;
  }
  while(my $l = <F>) {
    print T $l;
  }
  close(F);
  close(T);
  unlink($from);
}

#####################################
# Make a directory and its parent directories if needed.
sub
HandleArchiving($)
{
  my ($log) = @_;
  my $ln = $log->{NAME};
  return if(!$attr{$ln});

  # If there is a command, call that
  my $cmd = $attr{$ln}{archivecmd};
  if($cmd) {
    $cmd =~ s/%/$log->{currentlogfile}/g;
    Log 2, "Archive: calling $cmd";
    system($cmd);
    return;
  }

  my $nra = $attr{$ln}{nrarchive};
  my $ard = $attr{$ln}{archivedir};
  return if(!defined($nra));

  # If nrarchive is set, then check the last files:
  # Get a list of files:

  my ($dir, $file);
  if($log->{logfile} =~ m,^(.+)/([^/]+)$,) {
    ($dir, $file) = ($1, $2);
  } else {
    ($dir, $file) = (".", $log->{logfile});
  }

  $file =~ s/%./.+/g;
  return if(!opendir(DH, $dir));
  my @files = sort grep {/^$file$/} readdir(DH);
  closedir(DH);

  my $max = int(@files)-$nra;
  for(my $i = 0; $i < $max; $i++) {
    if($ard) {
      Log 2, "Moving $files[$i] to $ard";
      myrename("$dir/$files[$i]", "$ard/$files[$i]");
    } else {
      Log 2, "Deleting $files[$i]";
      unlink("$dir/$files[$i]");
    }
  }
}

#####################################
# Call a logical device (FS20) ParseMessage with data from a physical device
# (FHZ)
sub
Dispatch($$$)
{
  my ($hash, $dmsg, $addvals) = @_;
  my $iohash = $modules{$hash->{TYPE}}; # The phyiscal device module pointer
  my $name = $hash->{NAME};

  Log 5, "$name dispatch $dmsg";

  my ($isdup, $idx) = CheckDuplicate($name, $dmsg);
  if($isdup) {
    my $found = $duplicate{$idx}{FND};
    foreach my $found (@{$found}) {
      if($addvals) {
        foreach my $av (keys %{$addvals}) {
          $defs{$found}{"${name}_$av"} = $addvals->{$av};
        }
      }
      $defs{$found}{"${name}_MSGCNT"}++;
      $defs{$found}{"${name}_TIME"} = TimeNow();
    }
    return $duplicate{$idx}{FND};
  }

  my @found;

  my $cl = $hash->{Clients};
  $cl = $iohash->{Clients} if(!$cl);

  foreach my $m (sort { $modules{$a}{ORDER} cmp $modules{$b}{ORDER} }
                  grep {defined($modules{$_}{ORDER})} keys %modules) {

    next if(!(defined($cl) && $cl =~ m/:$m:/));

    # Module is not loaded or the message is not for this module
    next if(!$modules{$m}{Match} || $dmsg !~ m/$modules{$m}{Match}/i);

    no strict "refs";
    @found = &{$modules{$m}{ParseFn}}($hash,$dmsg);
    use strict "refs";
    last if(int(@found));
  }

  if(!int(@found)) {
    my $h = $hash->{MatchList}; $h = $iohash->{MatchList} if(!$h);
    if(defined($h)) {
      foreach my $m (sort keys %{$h}) {
        if($dmsg =~ m/$h->{$m}/) {
          my ($order, $mname) = split(":", $m);

          if($attr{global}{autoload_undefined_devices}) {
            $mname = LoadModule($mname);
            if($modules{$mname} && $modules{$mname}{ParseFn}) {
              no strict "refs";
              @found = &{$modules{$mname}{ParseFn}}($hash,$dmsg);
              use strict "refs";
            } else {
              Log 0, "ERROR: Cannot autoload $mname";
            }

          } else {
            Log GetLogLevel($name,3),
                "$name: Unknown $mname device detected, " .
                        "define one to get detailed information.";
            return undef;

          }
        }
      }
    }
    if(!int(@found)) {
      Log GetLogLevel($name,3), "$name: Unknown code $dmsg, help me!";
      return undef;
    }
  }

  ################
  # Inform raw
  if(!$iohash->{noRawInform}) {
    foreach my $c (keys %client) {
      next if(!$client{$c}{inform} || $client{$c}{inform} ne "raw");
      syswrite($client{$c}{fd}, "$hash->{TYPE} $name $dmsg\n");
    }
  }

  return undef if($found[0] eq "");	# Special return: Do not notify

  foreach my $found (@found) {

    if($found =~ m/^(UNDEFINED.*)/) {
      DoTrigger("global", $1);
      return undef;

    } else {
      if($defs{$found}) {
        $defs{$found}{MSGCNT}++;
        my $avtrigger = ($attr{$name} && $attr{$name}{addvaltrigger});
        if($addvals) {
          foreach my $av (keys %{$addvals}) {
            $defs{$found}{"${name}_$av"} = $addvals->{$av};
            push(@{$defs{$found}{CHANGED}}, "$av: $addvals->{$av}")
              if($avtrigger);
          }
        }
        $defs{$found}{"${name}_MSGCNT"}++;
        $defs{$found}{"${name}_TIME"} = TimeNow();
        $defs{$found}{LASTIODev} = $name;
      }
      DoTrigger($found, undef);
    }
  }

  $duplicate{$idx}{FND} = \@found;

  return \@found;
}

sub
CheckDuplicate($$)
{
  my ($ioname, $msg) = @_;

  # Store only the "relevant" part, as the CUL won't compute the checksum
  $msg = substr($msg, 8) if($msg =~ m/^81/ && length($msg) > 8);

  my $now = gettimeofday();
  my $lim = $now-AttrVal("global","dupTimeout", 0.5);

  foreach my $oidx (keys %duplicate) {
    if($duplicate{$oidx}{TIM} < $lim) {
      delete($duplicate{$oidx});

    } elsif($duplicate{$oidx}{MSG} eq $msg &&
            $duplicate{$oidx}{ION} ne $ioname) {
      return (1, $oidx);

    }
  }
  $duplicate{$duplidx}{ION} = $ioname;
  $duplicate{$duplidx}{MSG} = $msg;
  $duplicate{$duplidx}{TIM} = $now;
  $duplidx++;
  return (0, $duplidx-1);
}

sub
AddDuplicate($$)
{
  $duplicate{$duplidx}{ION} = shift;
  $duplicate{$duplidx}{MSG} = shift;
  $duplicate{$duplidx}{TIM} = gettimeofday();
  $duplidx++;
}

sub
SecondsTillTomorrow($)  # 86400, if tomorrow is no DST change
{
  my $t = shift;
  my $day = int($t/86400);

  if(!$stt_day || $day != $stt_day) {
    my $t = $day*86400+12*3600;
    my @l1 = localtime($t);
    my @l2 = localtime($t+86400);
    $stt_sec = 86400+
                ($l1[2]-$l2[2])*3600+
                ($l1[1]-$l2[1])*60;
    $stt_day = $day;
  }

  return $stt_sec;
}

sub
ReadingsVal($$$)
{
  my ($d,$n,$default) = @_;
  if(defined($defs{$d}) &&
     defined($defs{$d}{READINGS}) &&
     defined($defs{$d}{READINGS}{$n}) &&
     defined($defs{$d}{READINGS}{$n}{VAL})) {
     return $defs{$d}{READINGS}{$n}{VAL};
  }
  return $default;
}

sub
Value($)
{
  my ($d) = @_;
  if(defined($defs{$d}) &&
     defined($defs{$d}{STATE})) {
     return $defs{$d}{STATE};
  }
  return "";
}

sub
OldValue($)
{
  my ($d) = @_;
  return $oldvalue{$d}{VAL} if(defined($oldvalue{$d})) ;
  return "";
}

sub
OldTimestamp($)
{
  my ($d) = @_;
  return $oldvalue{$d}{TIME} if(defined($oldvalue{$d})) ;
  return "";
}




sub
AttrVal($$$)
{
  my ($d,$n,$default) = @_;
  return $attr{$d}{$n} if($d && defined($attr{$d}) && defined($attr{$d}{$n}));
  return $default;
}

# Add an attribute to the userattr list, if not yet present
sub
addToAttrList($)
{
  my $arg = shift;

  my $ua = "";
  $ua = $attr{global}{userattr} if($attr{global}{userattr});
  my @al = split(" ", $ua);
  my %hash;
  foreach my $a (@al) {
    $hash{$a} = 1;
  }
  $hash{$arg} = 1;
  $attr{global}{userattr} = join(" ", sort keys %hash);
}

# $dir: 0 = User to Fhem (i.e. set), 1 = Fhem to User (i.e trigger)
sub
ReplaceEventMap($$$)
{
  my ($dev, $str, $dir) = @_;
  my $em = $attr{$dev}{eventMap};
  return $str if(!$em);

  my $sc = " ";               # Split character
  my $fc = substr($em, 0, 1); # First character of the eventMap
  if($fc eq "," || $fc eq "/") {
    $sc = $fc;
    $em = substr($em, 1);
  }

  my $nstr = join(" ", @{$str}) if(!$dir);
  my $changed;
  foreach my $rv (split($sc, $em)) {
    my ($re, $val) = split(":", $rv, 2);
    next if(!defined($val));
    if($dir) {  # event -> Presentation
      if($str =~ m/$re/) {
        $str =~ s/$re/$val/;
        $changed = 1;
        last;
      }

    } else {    # Setting event
      if($nstr =~ m/$val/) {
        $nstr =~ s/$val/$re/;
        $changed = 1;
        last;
      }

    }
  }
  return $str if($dir);
  return split(" ",$nstr) if($changed);
  return @{$str};
}

sub
setGlobalAttrBeforeFork()
{
  my $f = $attr{global}{configfile};
  open(FH, $f) || die("Cant open $f: $!\n");
  while(my $l = <FH>) {
    $l =~ s/[\r\n]//g;
    next if($l !~ m/^attr\s+global\s+([^\s]+)\s+(.*)$/);
    my ($n,$v) = ($1,$2);
    $v =~ s/#.*//;
    $v =~ s/ .*$//;
    $attr{global}{$n} = $v;
  }
  close(FH);
}
