#=Head1 NAME - Bio::EnsEMBL::DBSQL::DBConnection

=head1 SYNOPSIS

    $db = Bio::EnsEMBL::DBSQL::DBConnection->new(
        -user   => 'root',
        -dbname => 'pog',
        -host   => 'caldy',
        -driver => 'mysql',
        );


   You should use this as a base class for all objects (DBAdaptor) that 
   connect to a database. 

   $sth = $db->prepare( "SELECT something FROM yourtable" );

   If you go through prepare you could log all your select statements.

   If you want to share a database handle with other database connections
   you can do the following:

   $db2 = Bio::EnsEMBL::DBSQL::DBConnection->new(-dbconn => $db);

=head1 DESCRIPTION

  This only wraps around the perl DBI->connect call, 
  so you dont have to remember how to do this.

=head1 CONTACT

  This module is part of the Ensembl project: www.ensembl.org

  Ensembl development mailing list: <ensembl-dev@ebi.ac.uk>

=head1 METHODS

=cut


package Bio::EnsEMBL::DBSQL::DBConnection;

use vars qw(@ISA);
use strict;

use Bio::EnsEMBL::Container;
use Bio::EnsEMBL::Root;
use DBI;

use Bio::EnsEMBL::Utils::Exception qw(throw info warning);
use Bio::EnsEMBL::Utils::Argument qw(rearrange);

@ISA = qw(Bio::EnsEMBL::Root);


=head2 new

  Arg [DBNAME] : string
                 The name of the database to connect to.
  Arg [HOST] : (optional) string
               The domain name of the database host to connect to.  
               'localhost' by default. 
  Arg [USER] : string
               The name of the database user to connect with 
  Arg [PASS] : (optional) string
               The password to be used to connect to the database
  Arg [PORT] : int
               The port to use when connecting to the database
               3306 by default.
  Arg [DRIVER] : (optional) string
                 The type of database driver to use to connect to the DB
                 mysql by default.
  Example    : $dbc = Bio::EnsEMBL::DBSQL::DBConnection->new
                  (-user=> 'anonymous',
                   -dbname => 'pog',
                   -host   => 'caldy',
                   -driver => 'mysql');

               $dbc2 = Bio::EnsEMBL::DBSQL::DBConnection->new(-DBCONN => $dbc);
  Description: Constructor for a DatabaseConenction. Any adaptors that require
               database connectivity should inherit from this class.
  Returntype : Bio::EnsEMBL::DBSQL::DBConnection 
  Exceptions : thrown if USER or DBNAME are not specified, or if the database
               cannot be connected to.
  Caller     : Bio::EnsEMBL::DBSQL::DBAdaptor

=cut

sub new {
  my $class = shift;

  my ($db, $dbconn,$host,$driver,$user,$password,$port) =
    rearrange([qw(DBNAME DBCONN HOST DRIVER USER PASS PORT)],@_);

  my $self = {};
  bless $self, $class;

  if($dbconn) {
    if(!ref($dbconn) || !$dbconn->isa('Bio::EnsEMBL::DBSQL::DBConnection')) {
      throw("Bio::EnsEMBL::DBSQL::DBConnection argument expected.");
    }

    #share a common db_handle, use a shared scalar ref_count to track # connections
    my $rcount = $dbconn->ref_count();
    $$rcount++; # dereference and increment shared var
    $self->ref_count($rcount);
    $self->db_handle($dbconn->db_handle());

    $self->driver($dbconn->driver());
    $self->host($dbconn->host());
    $self->port($dbconn->port());
    $self->dbname($dbconn->dbname());
    $self->username($dbconn->username());
    $self->password($dbconn->password());

    return Bio::EnsEMBL::Container->new($self);
  }

  $db   || throw("Database object must have a database name");
  $user || throw("Database object must have a user");

  if( ! $driver ) {
    $driver = 'mysql';
  }
  if( ! $host ) {
    $host = 'localhost';
  }
  if ( ! $port ) {
    $port = 3306;
  }

=head1
  my $dsn = "DBI:$driver:database=$db;host=$host;port=$port";

  my $dbh;
  eval{
    $dbh = DBI->connect("$dsn","$user",$password, {RaiseError => 1});
  };

  $dbh || throw("Could not connect to database $db user " .
		       "$user using [$dsn] as a locator\n" . $DBI::errstr);

  my $ref_count = 1;
  $self->ref_count(\$ref_count);
  $self->db_handle($dbh);
=cut

  $self->username( $user );
  $self->host( $host );
  $self->dbname( $db );
  $self->password( $password);
  $self->port($port);
  $self->driver($driver);

  $self->connect();
  
  # be very sneaky and actually return a container object which is outside
  # of the circular reference loops and will perform cleanup when all 
  # references to the container are gone.
  return new Bio::EnsEMBL::Container($self);
}


=head2 connect

  Example    : $db_connection->connect()
  Description: Explicitely connect to database if not connected
  Returntype : none
  Exceptions : none
  Caller     : new, db_handle

=cut

sub connect {
  my $self = shift;

  if($self->{'_db_handle'}) { return; }

  my $host      = $self->host();
  my $driver    = $self->driver();
  my $user      = $self->username();
  my $password  = $self->password();
  my $port      = $self->port();
  my $db        = $self->dbname();

  my $dsn = "DBI:$driver:database=$db;host=$host;port=$port";

  my $dbh;
  eval{
    $dbh = DBI->connect("$dsn","$user",$password, {RaiseError => 1});
  };

  $dbh || throw("Could not connect to database $db user " .
                "$user using [$dsn] as a locator\n" . $DBI::errstr);

  #print STDERR "DBConnection : CONNECT\n";
  my $ref_count = 1;
  $self->ref_count(\$ref_count);
  $self->{'_db_handle'} = $dbh;
}


=head2 driver

  Arg [1]    : (optional) string $arg
               the name of the driver to use to connect to the database
  Example    : $driver = $db_connection->driver()
  Description: Getter / Setter for the driver this connection uses.
               Right now there is no point to setting this value after a
               connection has already been established in the constructor.
  Returntype : string
  Exceptions : none
  Caller     : new

=cut

sub driver {
  my($self, $arg ) = @_;

  (defined $arg) &&
    ($self->{_driver} = $arg );
  return $self->{_driver};
}


=head2 port

  Arg [1]    : (optional) int $arg
               the TCP or UDP port to use to connect to the database
  Example    : $port = $db_connection->port();
  Description: Getter / Setter for the port this connection uses to communicate
               to the database daemon.  There currently is no point in 
               setting this value after the connection has already been 
               established by the constructor.
  Returntype : string
  Exceptions : none
  Caller     : new

=cut

sub port {
  my ($self, $arg) = @_;

  (defined $arg) && 
    ($self->{_port} = $arg );
  return $self->{_port};
}


=head2 dbname

  Arg [1]    : (optional) string $arg
               The new value of the database name used by this connection. 
  Example    : $dbname = $db_connection->dbname()
  Description: Getter/Setter for the name of the database used by this 
               connection.  There is currently no point in setting this value
               after the connection has already been established by the 
               constructor.
  Returntype : string
  Exceptions : none
  Caller     : new

=cut

sub dbname {
  my ($self, $arg ) = @_;
  ( defined $arg ) &&
    ( $self->{_dbname} = $arg );
  $self->{_dbname};
}


=head2 username

  Arg [1]    : (optional) string $arg
               The new value of the username used by this connection. 
  Example    : $username = $db_connection->username()
  Description: Getter/Setter for the username used by this 
               connection.  There is currently no point in setting this value
               after the connection has already been established by the 
               constructor.
  Returntype : string
  Exceptions : none
  Caller     : new

=cut

sub username {
  my ($self, $arg ) = @_;
  ( defined $arg ) &&
    ( $self->{_username} = $arg );
  $self->{_username};
}


=head2 host

  Arg [1]    : (optional) string $arg
               The new value of the host used by this connection. 
  Example    : $host = $db_connection->host()
  Description: Getter/Setter for the domain name of the database host use by 
               this connection.  There is currently no point in setting 
               this value after the connection has already been established 
               by the constructor.
  Returntype : string
  Exceptions : none
  Caller     : new

=cut

sub host {
  my ($self, $arg ) = @_;
  ( defined $arg ) &&
    ( $self->{_host} = $arg );
  $self->{_host};
}


=head2 password

  Arg [1]    : (optional) string $arg
               The new value of the password used by this connection. 
  Example    : $host = $db_connection->password()
  Description: Getter/Setter for the password of to use for 
               this connection.  There is currently no point in setting 
               this value after the connection has already been established 
               by the constructor.
  Returntype : string
  Exceptions : none
  Caller     : new

=cut

sub password {
  my ($self, $arg ) = @_;
  ( defined $arg ) &&
    ( $self->{_password} = $arg );
  $self->{_password};
}


=head2 ref_count

  Arg [1]    : (optional) ref to int $ref_count
  Example    : $count = 1; $self->ref_count(\$count);
  Description: Getter/setter for the number of existing references to
               this DBConnections database handle.  This is a reference to
               a scalar because it is shared by all database connections which
               share the same database handle.  This is used by the DESTROY
               method to decide whether it should disconnect from the database.
  Returntype : reference to int
  Exceptions : throw on bad argument
  Caller     : new

=cut

sub ref_count {
  my $self = shift;

  if(@_) {
    my $ref_count = shift;
    if(ref($ref_count) ne 'SCALAR') {
      throw("Reference to scalar argument expected.");
    }
    $self->{'ref_count'} = $ref_count;
  }
  return $self->{'ref_count'};
}


=head2 locator

  Arg [1]    : none
  Example    : $locator = $dbc->locator;
  Description: Constructs a locator string for this database connection
               that can, for example, be used by the DBLoader module
  Returntype : string
  Exceptions : none
  Caller     : general

=cut


sub locator {
  my $self = shift;

  my $ref;

  if($self->isa('Bio::EnsEMBL::Container')) {
    $ref = ref($self->_obj);
  } else {
    $ref = ref($self);
  }

  return "$ref/host=".$self->host.";port=".$self->port.";dbname=".
    $self->dbname.";user=".$self->username.";pass=".$self->password;
}


=head2 _get_adaptor

  Arg [1]    : string $module
               the fully qualified of the adaptor module to be retrieved
  Arg [2..n] : (optional) arbitrary list @args
               list of arguments to be passed to adaptors constructor
  Example    : $adaptor = $self->_get_adaptor("full::adaptor::name");
  Description: PROTECTED Used by subclasses to obtain adaptor objects
               for this database connection using the fully qualified
               module name of the adaptor. If the adaptor has not been 
               retrieved before it is created, otherwise it is retreived
               from the adaptor cache.
  Returntype : Adaptor Object of arbitrary type
  Exceptions : thrown if $module can not be instantiated
  Caller     : Bio::EnsEMBL::DBAdaptor

=cut

sub _get_adaptor {
  my( $self, $module, @args) = @_;

  if ($self->isa('Bio::EnsEMBL::Container')) {
    $self = $self->_obj;
  }

  my( $adaptor, $internal_name );

  #Create a private member variable name for the adaptor by replacing
  #:: with _

  $internal_name = $module;

  $internal_name =~ s/::/_/g;

  unless (defined $self->{'_adaptors'}{$internal_name}) {
    eval "require $module";

    if($@) {
      warning("$module cannot be found.\nException $@\n");
      return undef;
    }

    $adaptor = "$module"->new($self, @args);

    $self->{'_adaptors'}{$internal_name} = $adaptor;
  }

  return $self->{'_adaptors'}{$internal_name};
}


=head2 db_handle

  Arg [1]    : DBI Database Handle $value
  Example    : $dbh = $db_connection->db_handle() 
  Description: Getter / Setter for the Database handle used by this
               database connection.
  Returntype : DBI Database Handle
  Exceptions : none
  Caller     : new, DESTROY

=cut

sub db_handle {
   my ($self,$value) = @_;

   if( defined $value) {
      $self->{'_db_handle'} = $value;
   }
   else { $self->connect(); }
   return $self->{'_db_handle'};
}


=head2 prepare

  Arg [1]    : string $string
               the SQL statement to prepare
  Example    : $sth = $db_connection->prepare("SELECT column FROM table");
  Description: Prepares a SQL statement using the internal DBI database handle
               and returns the DBI statement handle.
  Returntype : DBI statement handle
  Exceptions : thrown if the SQL statement is empty, or if the internal
               database handle is not present
  Caller     : Adaptor modules

=cut

sub prepare {
   my ($self,$string) = @_;

   if( ! $string ) {
       throw("Attempting to prepare an empty SQL query.");
   }
   if( !defined $self->db_handle ) {
      throw("Database object has lost its database handle.");
   }

   #info("SQL(".$self->dbname."):$string");

   return $self->db_handle->prepare($string);
} 


=head2 add_db_adaptor

  Arg [1]    : string $name
               the name of the database to attach to this database
  Arg [2]    : Bio::EnsEMBL::DBSQL::DBConnection
               the db adaptor to attach to this database
  Example    : $db->add_db_adaptor('lite', $lite_db_adaptor);
  Description: Attaches another database instance to this database so 
               that it can be used in instances where it is required.
  Returntype : none
  Exceptions : none
  Caller     : EnsWeb

=cut

sub add_db_adaptor {
  my ($self, $name, $adaptor) = @_;

  unless($name && $adaptor && ref $adaptor) {
    throw('adaptor and name arguments are required');
  } 
				   
  #avoid circular references and memory leaks
  if($adaptor->isa('Bio::EnsEMBL::Container')) {
      $adaptor = $adaptor->_obj;
  }

  $self->{'_db_adaptors'}->{$name} = $adaptor;
}


=head2 remove_db_adaptor

  Arg [1]    : string $name
               the name of the database to detach from this database.
  Example    : $lite_db = $db->remove_db_adaptor('lite');
  Description: Detaches a database instance from this database and returns
               it.
  Returntype : none
  Exceptions : none
  Caller     : ?

=cut

sub remove_db_adaptor {
  my ($self, $name) = @_;

  my $adaptor = $self->{'_db_adaptors'}->{$name};
  delete $self->{'_db_adaptors'}->{$name};

  unless($adaptor) {
      return undef;
  }

  return $adaptor;
}


=head2 get_all_db_adaptors

  Arg [1]    : none
  Example    : @attached_dbs = values %{$db->get_all_db_adaptors()};
  Description: returns all of the attached databases as 
               a hash reference of key/value pairs where the keys are
               database names and the values are the attached databases  
  Returntype : hash reference with Bio::EnsEMBL::DBSQL::DBConnection values
  Exceptions : none
  Caller     : Bio::EnsEMBL::DBSQL::ProxyAdaptor

=cut

sub get_all_db_adaptors {
  my ($self) = @_;   

  unless(defined $self->{'_db_adaptors'}) {
    return {};
  }

  return $self->{'_db_adaptors'};
}



=head2 get_db_adaptor

  Arg [1]    : string $name
               the name of the attached database to retrieve
  Example    : $lite_db = $db->get_db_adaptor('lite');
  Description: returns an attached db adaptor of name $name or undef if
               no such attached database exists
  Returntype : Bio::EnsEMBL::DBSQL::DBConnection
  Exceptions : none
  Caller     : ?

=cut

sub get_db_adaptor {
  my ($self, $name) = @_;

  unless($self->{'_db_adaptors'}->{$name}) {
      return undef;
  }

  return $self->{'_db_adaptors'}->{$name};
}



sub deleteObj {
  my $self = shift;
  
  #print STDERR "DBConnection::deleteObj : Breaking circular references:\n";
  
  if(exists($self->{'_adaptors'})) {
    foreach my $adaptor_name (keys %{$self->{'_adaptors'}}) {
      my $adaptor = $self->{'_adaptors'}->{$adaptor_name};

      #call each of the adaptor deleteObj methods
      if($adaptor && $adaptor->can('deleteObj')) {
        #print STDERR "\t\tdeleting adaptor\n";
        $adaptor->deleteObj();
      }

      #break dbadaptor -> object adaptor references
      delete $self->{'_adaptors'}->{$adaptor_name};
    }
  }

  #print STDERR "Cleaning up attached databases\n";

  #break dbadaptor -> dbadaptor references
  foreach my $db_name (keys %{$self->get_all_db_adaptors()}) {
    #print STDERR "\tbreaking reference to $db_name database\n";
    $self->remove_db_adaptor($db_name);
  }
}


=head2 DESTROY

  Arg [1]    : none
  Example    : none
  Description: Called automatically by garbage collector.  Should
               never be explicitly called.  The purpose of this destructor
               is to disconnect any active database connections.
  Returntype : none 
  Exceptions : none
  Caller     : Garbage Collector

=cut

sub DESTROY {
   my ($obj) = @_;

   #print STDERR "DESTROYING DBConnection\n";

   $obj->disconnect();
}


=head2 disconnect

  Example    : $db_connection->disconnect()
  Description: Explicitely disconnect from database if connected
  Returntype : none
  Exceptions : none
  Caller     : ?, DESTROY

=cut

sub disconnect {
  my $self = shift;

  my $dbh = $self->{'_db_handle'};

  if( $dbh ) {
    my $refcount = $self->ref_count();
    $$refcount--;
    #print STDERR "DBConnection : ref_count-- ";

    # Do not disconnect if the InactiveDestroy flag has been set
    # this can really screw up forked processes.
    # Also: do not disconnect if this database handle is shared by
    # other DBConnections (as indicated by the refcount)
    if(!$dbh->{'InactiveDestroy'} && $$refcount == 0) {
      $dbh->disconnect;
      #print STDERR ": DISCONNECT ";
    }
    #print STDERR "\n";

    $self->{'_db_handle'} = undef;
    #unlink shared ref_count variable since no longer sharing db_handle
    my $unlinked_refcount = 0;
    $self->ref_count(\$unlinked_refcount);  
  }

}

1;
