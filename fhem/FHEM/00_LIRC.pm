##############################################
package main;

use strict;
use warnings;
use Time::HiRes qw(gettimeofday);
use Lirc::Client;
use IO::Select;

#####################################
# Note: we are a data provider _and_ a consumer at the same time
sub
LIRC_Initialize($)
{
  my ($hash) = @_;
  Log 1, "LIRC_Initialize";

# Provider
  $hash->{ReadFn}  = "LIRC_Read";
  $hash->{ReadyFn} = "LIRC_Ready";
  $hash->{Clients} = ":LIRC:";

# Consumer
  $hash->{DefFn}   = "LIRC_Define";
  $hash->{UndefFn} = "LIRC_Undef";
}

#####################################
sub
LIRC_Define($$)
{
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  $hash->{STATE} = "Initialized";

  $hash->{LircObj}->clean_up() if($hash->{LircObj});
  delete $hash->{LircObj};
  delete $hash->{FD};

  my $name = $a[0];
  my $config = $a[2];

  Log 3, "LIRC opening $name device $config";
  my $lirc = Lirc::Client->new({
        prog    => 'fhem',
        rcfile  => "$config", 
        debug   => 0,
        fake    => 0,
    });
  return "Can't open $config: $!\n" if(!$lirc);
  Log 3, "LIRC opened $name device $config";

  my $select = IO::Select->new();
  $select->add( $lirc->sock );

  $hash->{LircObj} = $lirc;
  
  $hash->{FD} = $lirc->{sock};       # is not working and sets timeout to undefined 
  $selectlist{"$name"} = $hash;      # 
  $readyfnlist{"$name"} = $hash;     # thats why we start polling
  $hash->{SelectObj} = $select;      
  $hash->{DeviceName} = $name;    
  $hash->{STATE} = "Opened";

  return undef;
}

#####################################
sub
LIRC_Undef($$)
{
  my ($hash, $arg) = @_;

  $hash->{LircObj}->clean_up() if($hash->{LircObj});
  delete $hash->{LircObj};
  delete $hash->{FD};

  return undef;
}

#####################################
sub
LIRC_Read($)
{
  my ($hash) = @_;

  my $lirc= $hash->{LircObj};
  my $select= $hash->{SelectObj};

  if( my @ready = $select->can_read(0) ){ 
    # an ir event has been received (if you are tracking other filehandles, you need to make sure it is lirc)
    my @codes = $lirc->next_codes;    # should not block
    for my $code (@codes){
      Log 3, "LIRC $code toggle";
      DoTrigger($code, "toggle");
    }
  }

}

#####################################
sub
LIRC_Ready($)
{
  my ($hash) = @_;

  my $select= $hash->{SelectObj};

  return $select->can_read(0);
}

1;
