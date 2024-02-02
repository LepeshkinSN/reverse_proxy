#!/usr/bin/perl -w
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
								"service_0"		=>	"192.168.1.1:80",
								"service_1"		=>	"192.168.1.2:443"
							);						# Hash of port -> service_name
my $ctrl_port = 40000;
my $ext_server = "110.120.130.140";
my $reverse_timeout=180;	# Timeout of waiting for reverse connection
my $iobuf_read_len=1024*1024;	# Data exchange buffer size
################# End of Settings ######################

my (
    %Children,              # hash of outstanding child processes
		%Children_reverse_ports,# Hash to store children ports
    $proxy_server,          # the sockets we accept() from
    $ME,                    # basename of this program
		$root_pid,							# pid of root process
		$restart_proxys					# Flag for proxys restart logic
);

# Save pid of the master process for childrens
$root_pid=$$;

# Enable output autoflush
STDOUT->autoflush(1);
STDERR->autoflush(1);

$SIG{TERM}= sub{
	print("$$: Caught SIGTERM. Killing childrens and exiting...\n");
	remove_childrens();
	exit 0;
};

start_proxy();
service_clients();

die "$$: NOT REACHED";          # you can't get here from there


sub remove_childrens{
	# Killing all children processes
	my $child;
	foreach $child (keys %Children){
		print("$$: Killing child $child\n");
		kill('TERM',$child);
		waitpid($child,WUNTRACED);
		delete($Children{$child});
		delete($Children_reverse_ports{$child});
	}
}

# begin our server 
sub start_proxy {
	# Creates listening socket.

	# Open listening socket for incoming connection

	$proxy_server = IO::Socket::INET->new(	LocalPort => $ctrl_port,
																					Proto     => 'tcp',
																					Reuse     => 1,
																					Listen    => SOMAXCONN,)
	                  or die "$$: ERROR: can't create listening socket for control connection on port $ctrl_port: $@\n";
		print "$$: [INIT: Proxy server control connection port $ctrl_port initialized.]\n";
}


sub service_clients { 
	# Main activity for listening children servers
	# Listen for incoming control connections, parse command, create reverse and local connections
  my (
			$ctrl_conn,									# control connection
			$ctrl_info,
			$ctrl_cmd,									# Control command
      $local_conn,              	# connection to internal server
      $local_info,                # client's name/port information
      $kidpid,                    # spawned child for each connection
			$reverse_conn,							# reverse connection socket (accepted from $socket_in
			$reverse_info,							# reverse connection info
			$svc_name,									# service name
			$reverse_port,							# Port to connect reverse socket to
			$sel,												# select for binary io at final stage
			$iobuf,											# io buffer for binary io at final stage
			$ccpf,											# The Control Connection Print Flag (used in SIGPIPE 
  																# handler to verify this signal comes while printing to control connection)
  );

	$ccpf=0;
  $SIG{CHLD} = \&REAPER;          # harvest the moribund


	# Main proxy loop
  while (1) {
		print "$$: Waiting for new client on port ".$proxy_server->sockport()."\n";
		# An accepted connection here means someone outside wants in
		while( ! ($ctrl_conn = $proxy_server->accept()) ){}
    $ctrl_info = peerinfo($ctrl_conn);
    print("$$: [Control connection from $ctrl_info]\n");

		# Enable keepalives
		$ctrl_conn->setsockopt(SOL_SOCKET, SO_KEEPALIVE, 1);

		# Fork to serve accepted control connection
    $kidpid = fork();
		if (! defined($kidpid)){
			# fork() failed
			print("$$: WARNING: Can't fork: $! Closing control connection and rejecting client $ctrl_info\n");
			close ($ctrl_conn);
			next;
		}
    if ($kidpid) {
			# We are the parent
      $Children{$kidpid} = time();            # remember his start time
      close $ctrl_conn;  				              # no use to master
      next;                                # go get another client
    } 

		################################################################
		# We are the children - "Client X dedicated process"
		################################################################

		# We have no childrens yet
		%Children=();

		# Close unused sockets
		close($proxy_server);

		# Introduce ourselve
		print("$$: Serving control connection from $ctrl_info\n");

		# Get command
		while($ctrl_cmd=<$ctrl_conn>){
			$ctrl_cmd =~ s/\s+$//;
			if ($ctrl_cmd !~ /\d+\:[\w\!]+/){
				# Invalid command
				next;
			}
			($reverse_port,$svc_name)=split(/:/,$ctrl_cmd,2);
			if ($svc_name eq "!"){
				# Request to close reverse connection
				foreach $kidpid (keys %Children_reverse_ports){
					if ($Children_reverse_ports{$kidpid} == $reverse_port){
						kill('TERM', $kidpid);
						delete($Children{$kidpid});
						delete($Children_reverse_ports{$kidpid});
					}
				}
				next;
			}

			if (! exists($service_book{$svc_name})){
				# Unknown service
				print("$$: WARNING: request to use non-existent service: $svc_name\n");
				next;
			}

			# We have valid command to open connection
			print("$$: Command accepted: $ctrl_cmd\n");
			# Fork to serve command request
	    $kidpid = fork();
			if (! defined($kidpid)){
				# fork() failed
				print("$$: WARNING: Can't fork: $! Can't server command for client $ctrl_info\n");
				next;
			}
	    if ($kidpid) {
				# We are the parent
				$Children{$kidpid}=time();
	      $Children_reverse_ports{$kidpid} = $reverse_port;  # remember his reverse port
	      next;                                			# go get another command
	    } 

			####################################################################
			# We are the children - "Client X service Y dedicated process"
			####################################################################
			# We have no childrens yet
			%Children=();

			# Close unused sockets
			close($ctrl_conn);

			# Introduce ourselve
			print("$$: Establishing and serving $ext_server:$reverse_port <---> $service_book{$svc_name} connection.\n");

			# Connect reverse socket
			$reverse_conn = IO::Socket::INET->new("$ext_server:$reverse_port")
				or die "$$: Can't connect reverse socket to $ext_server:$reverse_port: $!\n";
			$local_conn = IO::Socket::INET->new($service_book{$svc_name})
				or die "$$: Can't connect local socket to $service_book{$svc_name}: $!\n";

			# Set binary I/O mode on sockets				
			binmode($local_conn);
			binmode($reverse_conn);

	    # Enable keepalives
	    $local_conn->setsockopt(SOL_SOCKET, SO_KEEPALIVE, 1);
	    $reverse_conn->setsockopt(SOL_SOCKET, SO_KEEPALIVE, 1);

	    # at this point, we are the child process dedicated
	    # to the incoming client and reverse connection.
			# but we want a twin to make i/o easier.
	    $kidpid = fork(); 
	    if (! defined($kidpid)){
				die "$$: Can't fork: $!\n";
			}

	    if ($kidpid) {       
				# We are the parent
				$Children{$kidpid}=time();
	 			$sel= IO::Select->new();
				$sel->add($local_conn);
				while($sel->can_read()){
	      	$local_conn->recv($iobuf,$iobuf_read_len);
					if(length($iobuf)==0){
						last;
					}
					$reverse_conn->send($iobuf);
				}
				print "$$: Local connection was closed. Killing children $kidpid and exiting.\n";
	      kill('TERM', $kidpid);      # kill my twin cause we're done
				close($reverse_conn);
				close($local_conn);
	    } 
	    else {                      
				###################################################################
				# We are the children - "Client X service Y dedicated process TWIN"
				###################################################################

				# Introduce ourselve
				print("$$: Complementing I/O for ".getppid()."\n");

	 			$sel= IO::Select->new();
				$sel->add($reverse_conn);
				while($sel->can_read()){
	      	$reverse_conn->recv($iobuf,$iobuf_read_len);
					if(length($iobuf)==0){
						last;
					}
					$local_conn->send($iobuf);
				}
				print "$$: Reverse connection was closed. Killing parent ".getppid()." and exiting.\n";
	      kill('TERM', getppid());    # kill my twin cause we're done
				close($local_conn);
				close($reverse_conn);
	    } 
	    exit;                           # whoever's still alive bites it
			
		}
		print("$$: Control connection closed. Exiting.\n");
		exit;
	}
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
						if (exists($Children_reverse_ports{$child})){
							delete($Children_reverse_ports{$child});
						}
        } else {
            print "$$: Bizarre kid $child exited $?\n";
        } 
    }
    # If I had to choose between System V and 4.2, I'd resign. --Peter Honeyman
    $SIG{CHLD} = \&REAPER; 
};
