#!/usr/bin/perl


################### TODO
# rendere fork invece di sequenziale i check http, così posso aumentare il timeout
# necessario però il print dei log con indicazione di quale figlio ha fatto l'output
# esempio:
# verificare le variabili però.... si rischia di non propagarle al padre.
### SEMPLICEMENTE: un fork/thread per ogni server da monitorare, così il fork ha accesso a tutti i dati del server stesso: fork/thread->while->check
#my %pids = {};
#while ($c < 10){
#  foreach $k (@servers)
#  {
#    my $pid = fork();
#    $pids{$k} = $pid;
#    if ($pid == 0)
#    {
#      # child operations;
#      sleep (10);
#      exit 0;
#    }
#  }
#  foreach $k (@servers) {
#    waitpid($pids{$k},0);
#  }
#  sleep 60;
#  $c++;
#}




### UID TO RUN ON
$uid = int(getpwnam('lbwwd'));
## uid of lbwwd user




# options:
#   i: polling interval
#   b: backend group name
#   s: servers = name:ip:port list (separati da ,)
#   l: log file
#   p: pid file
#   k: haproxy socket file
#   u: url



use Getopt::Std;
use Proc::Daemon;
use IO::Handle;
use IO::Socket::UNIX;
use LWP;

# declare the perl command line flags/options we want to allow
my %options=();
getopts("i:b:s:l:p:k:u:", \%options);


# test for the existence of the options on the command line.
# in a normal program you'd do more than just print these.
#print "-i $options{i}\n" if defined $options{i};
#print "-b $options{b}\n" if defined $options{b};
#print "-s $options{s}\n" if defined $options{s};
#print "-l $options{l}\n" if defined $options{l};
#print "-p $options{p}\n" if defined $options{p};
#exit;

if (!defined $options{i}){
  print STDERR "ERR_INVALID_OPTIONS\n";
  exit 1;
}

if (!defined $options{b}){
  print STDERR "ERR_INVALID_OPTIONS\n";
  exit 1;
}

if (!defined $options{s}){
  print STDERR "ERR_INVALID_OPTIONS\n";
  exit 1;
}

if (!defined $options{l}){
  print STDERR "ERR_INVALID_OPTIONS\n";
  exit 1;
}

if (!defined $options{p}){
  print STDERR "ERR_INVALID_OPTIONS\n";
  exit 1;
}

if (!defined $options{k}){
  print STDERR "ERR_INVALID_OPTIONS\n";
  exit 1;
}

if (!defined $options{u}){
  print STDERR "ERR_INVALID_OPTIONS\n";
  exit 1;
}


$pidfile = $options{p};
$logfile = $options{l};
$interval = int($options{i});
$backgroup = $options{b};
$servers_s = $options{s};
$socket = $options{k};
$url_param = $options{u};

$check_host = "";
$check_url = "";

if (index($url_param, ":")>=0)
{
  ($check_host, $check_url) = split(/:/, $url_param);
}
else
{
  $check_url = $url_param;
}


@servers = split(',', $servers_s);

if (-e $pidfile) {
  print STDERR "ERR_PID_FILE_EXISTS\n";
  exit 1;
} 



Proc::Daemon::Init({
  work_dir	=> '/srv/spool/lbwwd/',
  setuid	=> $uid,
  pid_file	=> "$pidfile",
});



my $continue = 1;
$SIG{TERM} = sub { $continue = 0 };

open(L, ">> $logfile");
L->autoflush(1);


# inizializza l'hash degli stati dei server
# e disabilita inizialmente i server

my %serv_status = {};
my %serv_weight = {};

foreach $k (@servers) {
  @params = split(/:/, $k);
  $name = $params[0];
  print L " -> base disabling $name\n";
  $serv_status{$name} = 'disabled';
  $out = &disable_server($socket, "$backgroup/$name");
  
  $w = &get_weight($socket, "$backgroup/$name");
  print L " -> base weight $name = $w\n";
  $serv_weight{$name} = int($w);
}

while ($continue) {
  
  print L "SERVER CHECK\n";
  foreach $k (@servers) {
    @params = split(/:/, $k);
    $name = $params[0];
    $ip = $params[1];
    $port = $params[2];
    if ($name eq '') { print L "WARN name null\n"; }
    #if (1){
      print L "NAME: $name * IP: $ip * PORT: $port\n";
      print L "H: $check_host * U: $check_url\n";
      $load = &get_server_load($ip, $port, $check_url, $check_host);
      print L "LOAD: *$load*\n";
      if ($load == -1)
      {
        print L " * Server response ERROR (-1)\n";
        if ($serv_status{$name} eq 'enabled')
        {
          print L "    >> Server is enabled and should be disabled\n";
          $out = &disable_server($socket, "$backgroup/$name");
          $serv_status{$name} = 'disabled';
        }
      }
      else
      {
        print L " * Server response OK ($load)\n";
        if ($serv_status{$name} eq 'disabled')
        {
          print L "    >> Server is disabled and should be enabled\n";
          $out = &enable_server($socket, "$backgroup/$name");
          $serv_status{$name} = 'enabled';
        }
        # change weight
        $newweight = 100 - $load;
        $oldweight = int($serv_weight{$name});
        if ($oldweight != $newweight)
        {
          print L " * NEW WEIGHT: $newweight\n";
          $out = &set_weight($socket, "$backgroup/$name", $newweight);
          $serv_weight{$name} = int($newweight);
        }
        else
        {
          print L " * WEIGHT unchanged: $newweight\n";
        }
      }
      
      print L "***************\n"
    #}
  }
  
  # sleep until next cycle
  sleep $interval;
}

close (L);
exit 0;


sub get_weight {
  my ($a1) = shift;
  my ($a2) = shift;
  my $sock = new IO::Socket::UNIX (Peer => $a1, Type => SOCK_STREAM, Timeout => 1);
  return 0 if !$sock;
  print $sock "get weight $a2\n";
  my $z = "";
  while(<$sock>) {
    $z = $z . $_;
  }
  if ($z =~ /^([0-9]+).+/)
  {
    return int($1);
  }
  else
  {
    return 0;
  }
}

sub set_weight {
  my ($a1) = shift;
  my ($a2) = shift;
  my ($a3) = shift;
  $w = int($a3);
  my $sock = new IO::Socket::UNIX (Peer => $a1, Type => SOCK_STREAM, Timeout => 1);
  return -1 if !$sock;
  print $sock "set weight $a2 $w\n";
  my $z = "";
  while(<$sock>) {
    $z = $z . $_;
  }
  return $w;
}

sub enable_server {
  my ($a1) = shift;
  my ($a2) = shift;
  my $sock = new IO::Socket::UNIX (Peer => $a1, Type => SOCK_STREAM, Timeout => 1);
  return -1 if !$sock;
  print $sock "enable server $a2\n";
  my $z = "";
  while(<$sock>) {
    $z = $z . $_;
  }
  return $w;
}

sub disable_server {
  my ($a1) = shift;
  my ($a2) = shift;
  my $sock = new IO::Socket::UNIX (Peer => $a1, Type => SOCK_STREAM, Timeout => 1);
  return -1 if !$sock;
  print $sock "disable server $a2\n";
  my $z = "";
  while(<$sock>) {
    $z = $z . $_;
  }
  return $w;
}

sub get_server_load {
  my ($ip) = shift;
  my ($port) = shift;
  my ($url) = shift;
  my ($host) = shift || "";
  
  my $ua = new LWP::UserAgent('agent' => "lbwwd/0.9");
  my $secs = 5;
  $ua->timeout( $secs );
  my $req_url = "http://" . $ip . ":" . $port . $url;
  my $request = new HTTP::Request('GET', $req_url);
  if ($host ne "") {
    $request->header('Host', $host);
  }
  my $response = $ua->request($request);
  my $content = "";
  if ($response->is_success) { $content=$response->content; }
  else { return -1; }
  if ($content =~ /LOAD=([0-9]+)/){ return $1; }
  else { return -1; }
}

