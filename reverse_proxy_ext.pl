#!/usr/bin/perl -w
# External reverse socket connector
# (C) Sergey Lepeshkin, 2023. LepeshkinSN@gmail.com
# Based on fwdport from Perl Cookbook by By Tom Christiansen & Nathan Torkington.
# This is free software. You may do whatever you want with it until
# authorship info is left intact.


use strict;                 # require declarations
use Net::hostent;           # by-name interface for host info
use IO::Socket;             # for creating server and client sockets
use POSIX ":sys_wait_h";    # for reaping our dead children
use IO::Select;

################# Settings #############################
my %service_book=(
                12345		=>	"service_0",
                12123		=>	"service_1"
              );						# Hash of port -> service_name
my $int_server="192.168.10.1:40000"; # Internal server request connection
my $port_pool_start=40001;  # Begin of port pool
my $port_pool_end=40250;  # End of port pool
my $reverse_timeout=180;	# Timeout of waiting for reverse connection
my $iobuf_read_len=1024*1024;	# Data exchange buffer size
my $start_tries=5;					# Number of retries to establish control connection at start
################# End of Settings ######################

my (
    %Children,              # hash of outstanding child processes
    $proxy_server,          # the sockets we accept() from
    $ctrl_conn,							# control connection to internal server
    $ME,                    # basename of this program
    $root_pid,							# pid of root process
    $restart_proxys					# Flag for proxys restart logic
);

# Save pid of the master process for childrens
$root_pid=$$;

# Turn autoflush on
STDOUT->autoflush(1);
STDERR->autoflush(1);

sub debug_sig_handler{
  my($sig) = @_;
  print("$$: Caught SIG$sig, ignoring.\n");
}

# Set SIGPIPE handler
$SIG{HUP}= \&debug_sig_handler;
$SIG{INT}= \&debug_sig_handler;
$SIG{PIPE}= \&debug_sig_handler;
$SIG{ALRM}= \&debug_sig_handler;
$SIG{USR2}= \&debug_sig_handler;
$SIG{POLL}= \&debug_sig_handler;
$SIG{PROF}= \&debug_sig_handler;
$SIG{VTALRM}= \&debug_sig_handler;
#$SIG{EMT}= \&debug_sig_handler;
$SIG{STKFLT}= \&debug_sig_handler;
$SIG{IO}= \&debug_sig_handler;
$SIG{PWR}= \&debug_sig_handler;
#$SIG{LOST}= \&debug_sig_handler;



#Set SIGTERM handler
$SIG{TERM}= sub{
  print("$$: Caught SIGTERM. Killing childrens and exiting...\n");
  remove_childrens();
  exit 0;
};

# Open control connection to internal server
# This connection would be managed by root process
# Trying to establish control connection
do{
  if ($ctrl_conn = IO::Socket::INET->new($int_server)){
    print "$$: [INIT: Control connection established.]\n";
  }
  else{
    warn "$$: Couldn't create control connection to $int_server : $!\n"; 
    sleep 30;
    $start_tries--;		
  }
} while ($start_tries && ! defined($ctrl_conn));

# Exit if control connection couldn't be established
if (! defined($ctrl_conn)){
  print("$$: Maximum retries to establish control connection reached. Exiting.\n");
  exit 1;
}

# Enable autoflush
$ctrl_conn->autoflush(1);
# Enable keepalives
$ctrl_conn->setsockopt(SOL_SOCKET, SO_KEEPALIVE, 1);

# Childrens will send this signals in case of control connection malfunction
$SIG{USR1} = \&check_ctrl_conn;

# Main loop
while(1){
  $restart_proxys=0;
  if(! start_proxys()) {       
    # We are the master process - install signal handler USR1 and sleep
    # Sleep until we got flag (set in check_ctrl_conn()) to restart proxys
    while(! $restart_proxys){
      sleep;
    }
  }
  else{
    ################################################################
    # We are the children - "Port Y server"
    # (fork was done in start_proxys())
    ################################################################
    # We are the children server process - go service clients
    # Restore default signal handlers
    $SIG{USR1} = 'DEFAULT';
    service_clients();          # wait for incoming
  }
}


die "$$: NOT REACHED";          # you can't get here from there

sub check_ctrl_conn{
  # This function will check whether control connection is ok
  # If it is not, then kill proxys and set flag to restart them
  print("$$: Caught signal SIGUSR1\n");
  # It seems control connection is broken. Let's check this...
  if( ! check_sock_connected($ctrl_conn)){
    # Connection is really dead
    print("$$: Detected dead control connection.\n");
    close($ctrl_conn);
    # Killing all children servers to re-spawn them with
    # new $ctrl_conn
    remove_childrens();
    # Trying to restore control connection
    do{
      sleep 10;
      if ($ctrl_conn = IO::Socket::INET->new($int_server)){
        print "$$: [INIT: Control connection RE-established.]\n";
      }
      else{
        warn "$$: Couldn't create control connection to $int_server : $!\n"; 
      }
    } while (! defined($ctrl_conn));
    # Enable autoflush
    $ctrl_conn->autoflush(1);
    # Enable keepalives
    $ctrl_conn->setsockopt(SOL_SOCKET, SO_KEEPALIVE, 1);
    # Set restart proxys flag
    $restart_proxys=1;
  }
}

sub remove_childrens{
  # Killing all children servers to re-spawn them with
  my $child;
  foreach $child (keys %Children){
    print("$$: Killing child $child\n");
    kill('TERM',$child);
    waitpid($child,WUNTRACED);
    delete($Children{$child});
  }
}

# begin our server 
sub start_proxys {
  # Creates listening sockets and children processes.
  # Returns:	0 - We are main controlling process
  # 					1 - We are children server
  my $port;
  my $can_start=0;
  my $kidpid;

  # Open listening sockets for incoming connections and,
  # if successfull, fork for each one
  foreach $port (keys %service_book){
    $proxy_server = IO::Socket::INET->new(	LocalPort => $port,
                                            Proto     => 'tcp',
                                            Reuse     => 1,
                                            Listen    => SOMAXCONN,)
                      or print "$$: WARNING: can't create listening socket on port $port: $@\n";
    if (defined $proxy_server){
      $kidpid = fork();
      if(! defined($kidpid)) {
        close($ctrl_conn);
        close($proxy_server);
        warn "$$: Cannot fork for serving port $port" ;
      }
      if ($kidpid) {
          # We are the parent
          $Children{$kidpid} = time();            # remember his start time
          close($proxy_server);                   # no use to master
          $can_start=1;
          next;                                   # go create another children server
      } 
      # We are the children
      # We have no childrens yet
      %Children=();
      # Print "Hello, world!"
      print "$$: [INIT: Proxy server on port $port initialized.]\n";
      return 1;
    }
  }
  
  # We are the parent
  # Check whether we have at least one listening socket. Die otherwise.
  if (! $can_start) {
    close($ctrl_conn);
    die "$$: No listening sockets and childrens created";
  }
  return 0;
}


sub service_clients { 
  # Main activity for listening children servers
  # Listen for incoming connections, search for free reverse port, send control command,
  # create fork, dedicated for client and etc...
  my (
      $client_conn,              # someone external wanting in
      $client_info,                   # client's name/port information
      $client_server_socket,             # the socket for connection from internal server
      $kidpid,                    # spawned child for each connection
      $port_in,										# port for connection from inside
      $socket_in,									# listening socket for connection from inside
      $reverse_conn,							# reverse connection socket (accepted from $socket_in
      $reverse_info,							# reverse connection info
      $reverse_timer,							# timer for waiting of reverse connection
      $sel,												# select for binary io at final stage
      $iobuf,											# io buffer for binary io at final stage
      $ccpf												# The Control Connection Print Flag (used in SIGPIPE 
                                  # handler to verify this signal comes while printing to control connection)
  );

  $ccpf=0;
  $SIG{CHLD} = \&REAPER;          # harvest the moribund
  $SIG{PIPE} = sub{
    if($ccpf){
      print("$$: Control connection failed. Closing reverse listening socket on port $port_in, rejecting client $client_info and exiting.\n");
      kill('USR1', $root_pid);
      close($proxy_server);
      close ($client_conn);
      close($socket_in);
      die "$$: Control connection failed\n";
    }
  };

  # Main children proxy loop
  while (1) {
      print "$$: Waiting for new client on port ".$proxy_server->sockport()."\n";
      # An accepted connection here means someone outside wants in
      while( ! ($client_conn = $proxy_server->accept()) ){}
      $client_info = peerinfo($client_conn);
      print "$$: Connect from $client_info to ".$proxy_server->sockport."\n";

      # Enable keepalives
      $client_conn->setsockopt(SOL_SOCKET, SO_KEEPALIVE, 1);

      # Create listening socket for connection from inside (reverse connection)
      $socket_in=undef;
      for ($port_in=$port_pool_start;($port_in<=$port_pool_end) && !defined($socket_in);){
        $socket_in = IO::Socket::INET->new(LocalPort => $port_in,
                                              Proto     => 'tcp',
                                              Reuse     => 1,
                                              Listen    => 1);
        if(! defined($socket_in)){
          $port_in++;
        }
      }

      # Test whether we've found free port to use
      # If not - reject client
      if (! defined($socket_in)){
        print("$$: WARNING: Can't create listening socket for reverse connection. May be there are no free ports. Rejecting client $client_info.\n");
        close ($client_conn);
        next;
      }

      # Fork before reverse connection established
      $kidpid = fork();
      if (! defined($kidpid)){
        print("$$: WARNING: Can't fork! Closing reverse listening socket on port $port_in and rejecting client $client_info\n");
        close ($client_conn);
        close($socket_in);
        next;
      }
      if ($kidpid) {
        # We are the parent
        $Children{$kidpid} = time();            # remember his start time
        close $client_conn;  				                 # no use to master
        close $socket_in;		                    # likewise
        next;                                # go get another client
      } 

      ################################################################
      # We are the children - "Client X dedicated process"
      ################################################################
      # We have no childrens yet
      %Children=();

      # Restore SIGPIPE handler to default
      $SIG{PIPE}='DEFAULT';

      # Requesting connection from inside
      print("$$: Requesting reverse connection ($port_in <--- ".$service_book{$proxy_server->sockport}.")...\n");
      $ccpf=1;
      print $ctrl_conn "$port_in:".$service_book{$proxy_server->sockport}."\n" or kill('PIPE', $root_pid);
      $ccpf=0;									
      print "$$: [Waiting for reverse connection...]\n";

      # We do not need listening socket here
      close($proxy_server);
      
      # Set client connection check mechanism
      $reverse_timer=0;
      $SIG{ALRM} = sub { 
        $reverse_timer++;
        if (($reverse_timer>=$reverse_timeout) || ! check_sock_connected($client_conn)){
          # Client disconnected
          print("$$: WARNING: Client disconnected while waiting for reverse connection. Closing reverse connection socket (port $port_in) and sending abort control command.\n");
          close ($socket_in);
          $ccpf=1;
          print $ctrl_conn "$port_in:!\n" or kill('PIPE', $root_pid);
          $ccpf=0;
          exit;
        }
        alarm 1;	# Set next alarm in 1 second
      };
      alarm 1;	# Set next alarm in 1 second
      # Block until reverse connection received
      while(! ($reverse_conn=$socket_in->accept())){};
      alarm 0;	#Disable alarm
      
      # Enable keepalives
      $reverse_conn->setsockopt(SOL_SOCKET, SO_KEEPALIVE, 1);

      # We've got reverse connection, let's close listening socket
      close($socket_in);
      $reverse_info = peerinfo($reverse_conn);
      print("$$: Accepted reverse connection from: $reverse_info\n");
      
      # Close control connection because we don't need it anymore
      close($ctrl_conn);

      # Set binary I/O mode on sockets				
      binmode($client_conn);
      binmode($reverse_conn);


      # at this point, we are the child process dedicated
      # to the incoming client and reverse connection.
      # but we want a twin to make i/o easier.
      $kidpid = fork(); 
      if (! defined($kidpid)){
        print("$$: WARNING: Can't fork! Closing reverse socket on port $port_in and rejecting client $client_info\n");
        close ($client_conn);
        close($socket_in);
        die "$$: Can't fork";
      }

      if ($kidpid) {       
        # We are the parent
        $Children{$kidpid} = time();            # remember his start time
        $sel= IO::Select->new();
        $sel->add($client_conn);
        while($sel->can_read()){
          $client_conn->recv($iobuf,$iobuf_read_len);
          if(length($iobuf)==0){
            last;
          }
          $reverse_conn->send($iobuf);
        }
        print "$$: Reverse connection was closed. Killing children $kidpid and exiting.\n";
        kill('TERM', $kidpid);      # kill my twin cause we're done
        close($reverse_conn);
      } 
      else {                      
        ################################################################
        # We are the children - "Client X dedicated process TWIN"
        ################################################################
        # We have no childrens yet
        %Children=();

        $sel= IO::Select->new();
        $sel->add($reverse_conn);
        while($sel->can_read()){
          $reverse_conn->recv($iobuf,$iobuf_read_len);
          if(length($iobuf)==0){
            last;
          }
          $client_conn->send($iobuf);
        }
        print "$$: Client connection was closed. Killing parent ".getppid()." and exiting.\n";
        kill('TERM', getppid());    # kill my twin cause we're done
        close($client_conn);
      } 
      # Mark used port as free
      exit;                           # whoever's still alive bites it
  }
}

#helper to check connection state

sub check_sock_connected{
  my $sockfd = shift;
  my $buff;
  my $ret;
  my $eno;
  if (!$sockfd->connected()){
    return 0;
  }
  $ret = $sockfd->recv($buff, 65535, MSG_PEEK | MSG_DONTWAIT);
  $eno = 0 + $!;
  if (($eno==0) && (length($buff)==0)){
    return 0;
  }
  return 1;

}

# helper function to produce a nice string in the form HOST:PORT
sub peerinfo {
    my $sock = shift;
    return sprintf("%s:%s", 
                    $sock->peerhost, 
                    $sock->peerport);
} 


# somebody just died.  keep harvesting the dead until 
# we run out of them.  check how long they ran.
sub REAPER { 
    my $child;
    my $start;
    while (($child = waitpid(-1,WNOHANG)) > 0) {
        if ($start = $Children{$child}) {
            my $runtime = time() - $start;
            printf "$$: Child $child ran %dm%ss\n", 
                $runtime / 60, $runtime % 60;
            delete $Children{$child};
        } else {
            print "$$: Bizarre kid $child exited $?\n";
        } 
    }
    # If I had to choose between System V and 4.2, I'd resign. --Peter Honeyman
    $SIG{CHLD} = \&REAPER; 
};
