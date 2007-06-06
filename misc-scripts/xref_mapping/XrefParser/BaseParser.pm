package XrefParser::BaseParser;

use strict;

use Carp;
use DBI;
use Digest::MD5 qw(md5_hex);
use Getopt::Long;
use POSIX qw(strftime);

use File::Basename;
use File::Spec::Functions;
use IO::File;
use Net::FTP;
use URI;
use URI::file;
use Text::Glob qw( match_glob );
use LWP::UserAgent;

use Bio::EnsEMBL::Utils::Exception;

my $base_dir = File::Spec->curdir();

my $add_xref_sth = undef;
my $add_direct_xref_sth = undef;
my $add_dependent_xref_sth = undef;
my $get_xref_sth = undef;
my $add_synonym_sth = undef;

my $dbi;
my %dependent_sources;
my %taxonomy2species_id;
my %name2species_id;

my (
    $host,         $port,    $dbname,
    $user,         $pass,    $create,
    $release,      $cleanup, $deletedownloaded,
    $skipdownload, $drop_db, $checkdownload,
    $dl_path,      $unzip
);

# --------------------------------------------------------------------------------
# Get info about files to be parsed from the database

sub run {
    my $self = shift;

    (  $host,           $port,             $dbname,
       $user,           $pass,             my $speciesr,
       my $sourcesr,    $skipdownload,     $checkdownload,
       $create,         $release,          $cleanup,
       $drop_db,        $deletedownloaded, $dl_path,
       my $notsourcesr, $unzip
    ) = @_;

    $base_dir = $dl_path if $dl_path;

    my @species    = @$speciesr;
    my @sources    = @$sourcesr;
    my @notsources = @$notsourcesr;

    my $sql_dir = dirname($0);

    if ($create) {
        create( $host, $port, $user, $pass, $dbname, $sql_dir,
                $drop_db );
    }

    my $dbi = dbi();

    # validate species names
    my @species_ids = validate_species(@species);

    # validate source names
    exit(1) if ( !validate_sources(@sources) );
    exit(1) if ( !validate_sources(@notsources) );

    # build SQL
    my $species_sql = "";
    if (@species_ids) {
        $species_sql .= " AND su.species_id IN (";
        for ( my $i = 0 ; $i < @species_ids ; $i++ ) {
            $species_sql .= "," if ( $i ne 0 );
            $species_sql .= $species_ids[$i];
        }
        $species_sql .= ") ";
    }

    my $source_sql = "";
    if (@sources) {
        $source_sql .= " AND LOWER(s.name) IN (";
        for ( my $i = 0 ; $i < @sources ; $i++ ) {
            $source_sql .= "," if ( $i ne 0 );
            $source_sql .= "\'" . lc( $sources[$i] ) . "\'";
        }
        $source_sql .= ") ";
    }

    if (@notsources) {
        $source_sql .= " AND LOWER(s.name) NOT IN (";
        for ( my $i = 0 ; $i < @notsources ; $i++ ) {
            $source_sql .= "," if ( $i ne 0 );
            $source_sql .= "\'" . lc( $notsources[$i] ) . "\'";
        }
        $source_sql .= ") ";
    }

    my $sql =
      "SELECT DISTINCT(s.source_id), su.source_url_id, s.name, su.url, "
      . "su.release_url, su.checksum, su.parser, su.species_id "
      . "FROM source s, source_url su, species sp "
      . "WHERE s.download='Y' AND su.source_id=s.source_id "
      . "AND su.species_id=sp.species_id "
      . $source_sql
      . $species_sql
      . "ORDER BY s.ordered";
    # print $sql . "\n";

    my $sth = $dbi->prepare($sql);
    $sth->execute();

    my ( $source_id, $source_url_id, $name, $url, $release_url,
         $checksum, $parser, $species_id );

    $sth->bind_columns( \$source_id,   \$source_url_id,
                        \$name,        \$url,
                        \$release_url, \$checksum,
                        \$parser,      \$species_id );

    my $dir;
    my %summary = ();

    while ( my @row = $sth->fetchrow_array() ) {
        print '-' x 4, "{ $name }", '-' x ( 72 - length($name) ), "\n";

        my $cs;
        my $file_cs = "";
        my $parse   = 0;
        my $empty   = 0;
        my $type    = $name;
        my $dsn;

        my @files = split( /\s+/, $url );
        my @files_to_parse = ();

        $dir = catdir( $base_dir, sanitise($type) );

        # For summary purposes: If 0 is returned (in
        # $summary{$name}->{$parser}) then it is successful.  If 1 is
        # returned then it failed.  If undef/nothing is returned the we
        # do not know.
        $summary{$name}->{$parser} = 0;

        @files = $self->fetch_files( $dir, @files );
        if ( !@files ) {
            # Fetching failed.
            ++$summary{$name}->{$parser};
            next;
        }
        if ( defined($release_url) ) {
            $release_url =
              $self->fetch_files( $dir, $release_url )->[-1];
        }

        foreach my $file (@files) {

            # Database parsing
            if ( $file =~ /^mysql:/i ) {
                $dsn = $file;
                print "Parsing $dsn with $parser\n";
                eval "require XrefParser::$parser";
                my $new = "XrefParser::$parser"->new();
                if (
                     $new->run( $dsn,  $source_id, $species_id,
                                $name, undef ) )
                {
                    ++$summary{$name}->{$parser};
                }
                next;
            }

            if (0) {
                # Local files need to be dealt with
                # specially; assume they are specified as
                # file:location/of/file/relative/to/xref_mapper

                my ($urls) = ( $file =~ s#^LOCAL:#file:# );

                my ($file) = $urls =~ /.*\/(.*)/;
                if ( $urls =~ /^file:(.*)/i ) {
                    my $local_file = $1;
                    if ( !defined( $cs = md5sum($local_file) ) ) {
                        print "Download '$local_file'\n";
                        ++$summary{$name}->{$parser};
                    } else {
                        $file_cs .= ':' . $cs;
                        if ( !defined $checksum
                             || index( $checksum, $file_cs ) == -1 )
                        {
                            print
                              "Checksum for '$file' does not match, "
                              . "will parse...\n";
                            print "Parsing local file '$local_file' "
                              . "with $parser\n";
                            eval "require XrefParser::$parser";
                            my $new = "XrefParser::$parser"->new();
                            if (
                                 $new->run( $source_id, $species_id,
                                            $local_file ) )
                            {
                                ++$summary{$name}->{$parser};
                            } else {
                                update_source( $dbi,     $source_url_id,
                                               $file_cs, $local_file );
                            }
                        } else {
                            print
                              "Ignoring '$file' as checksums match\n";
                        }
                    } ## end else [ if ( !defined( $cs = md5sum...
                    next;
                } ## end if ( $urls =~ /^file:(.*)/i)

                # This part deals with Zip archives.  It is unclear if
                # this is useful at all.  If so, then this should be
                # handled by the fatch_files() method.
                if (0) {
                   # Deal with URLs with '#' notation denoting filenames
                   # from archive If the '#' is used, set $file and
                   # $file_from_archive approprately.
                    my $file_from_archive;
                    if ( $file =~ /(.*)\#(.*)/ ) {
                        $file              = $1;
                        $file_from_archive = $2;
                        if ( !$file_from_archive ) {
                            croak(
"$file specifies a .zip file without using "
                                  . "the # notation to specify the file "
                                  . "in the archive to be used." );
                        }
                        print "Using $file_from_archive from $file\n";
                    }
                }
            } ## end if (0)

            if ( $unzip && ( $file =~ /\.(gz|Z)$/ ) ) {
                printf( "Uncompressing '%s' using 'gunzip'\n", $file );
                system( "gunzip", "-f", $file );
            }
            if ($unzip) {
                $file =~ s/\.(gz|Z)$//;  # If skipdownload set this will
                                         # not have been done yet.
                                         # If it has, no harm done
            }

            # Compare checksums and parse/upload if necessary need to
            # check file size as some .SPC files can be of zero length

            if ( !defined( $cs = md5sum($file) ) ) {
                printf( "Download '%s'\n", $file );
                ++$summary{$name}->{$parser};
            } else {
                $file_cs .= ':' . $cs;
                if ( !defined $checksum
                     || index( $checksum, $file_cs ) == -1 )
                {
                    if ( -s $file ) {
                        $parse = 1;
                        print "Checksum for '$file' does not match, "
                          . "will parse...\n";

                        # Files from sources "Uniprot/SWISSPROT" and
                        # "Uniprot/SPTREMBL" are all parsed with the
                        # same parser
                        if (    $parser eq "Uniprot/SWISSPROT"
                             || $parser eq "Uniprot/SPTREMBL" )
                        {
                            $parser = 'UniProtParser';
                        }
                    } else {
                        $empty = 1;
                        printf(
                            "The file '%s' has zero length, skipping\n",
                            $file );
                    }
                }
            } ## end else [ if ( !defined( $cs = md5sum...

            # Push this file to the list of files to parsed.  The files
            # are *actually* parsed only if $parse == 1.
            push @files_to_parse, $file;

        } ## end foreach my $file (@files)

        if ( $parse and @files_to_parse and defined $file_cs ) {
            print "Parsing '"
              . join( "', '", @files_to_parse )
              . "' with $parser\n";

            eval "require XrefParser::$parser";
            my $new = "XrefParser::$parser"->new();

            if ( defined $release_url ) {
                # Run with $release_url.
                if (
                     $new->run( $source_id,      $species_id,
                                @files_to_parse, $release_url ) )
                {
                    ++$summary{$name}->{$parser};
                }
            } else {
                # Run without $release_url.
                if (
                     $new->run( $source_id, $species_id,
                                @files_to_parse ) )
                {
                    ++$summary{$name}->{$parser};
                }
            }

            # update AFTER processing in case of crash.
            update_source( $dbi,     $source_url_id,
                           $file_cs, $files_to_parse[0] );

            # Set release if specified
            if ( defined $release ) {
                $self->set_release( $source_id, $release );
            }

        } elsif ( !$dsn && !$empty && @files_to_parse ) {
            print(   "Ignoring '"
                   . join( "', '", @files_to_parse )
                   . "' as checksums match\n" );
        }

        if ($cleanup) {
            foreach my $file (@files_to_parse) {
                printf( "Deleting '%s'\n", $file );
                unlink($file);
            }
        }

    } ## end while ( my @row = $sth->fetchrow_array...

    print "\n", '=' x 80, "\n";
    print "Summary of status\n";
    print '=' x 80, "\n";

    foreach my $source_name ( sort keys %summary ) {
        foreach my $parser_name ( keys %{ $summary{$source_name} } ) {
            printf( "%30s %-20s\t%s\n",
                    $source_name,
                    $parser_name, (
                       defined $summary{$source_name}->{$parser_name}
                         && $summary{$source_name}->{$parser_name}
                       ? 'FAILED'
                       : 'OKAY'
                    ) );
        }
    }

    # remove last working directory
    # TODO reinstate after debugging
    #rmtree $dir;

} ## end sub run

# ------------------------------------------------------------------------------

# Given one or several FTP or HTTP URIs, download them.  If an URI is
# for a file or MySQL connection, then these will be ignored.  For
# FTP, standard shell file name globbing is allowed (but not regular
# expressions).  HTTP does not allow file name globbing.  The routine
# returns a list of successfully downloaded local files or an empty list
# if there was an error.

sub fetch_files {
    my $self = shift;

    my ( $dest_dir, @user_uris ) = @_;

    my @processed_files;

    foreach my $user_uri (@user_uris) {
        # Change old-style 'LOCAL:' URIs into 'file:'.
        $user_uri =~ s#^LOCAL:#file:#i;

        my $uri = URI->new($user_uri);

        if ( $uri->scheme() eq 'file' ) {
            # Deal with local files.

            my @local_files;

            $user_uri =~ s/file://;
            if ( -f $user_uri ) {
                push( @processed_files, $user_uri );
            } else {
                printf( "==> Can not find file '%s'\n", $user_uri );
                return ();
            }
        } elsif ( $uri->scheme() eq 'ftp' ) {
            # Deal with FTP files.

            my $file_path =
              catfile( $dest_dir, basename( $uri->path() ) );

            if ( $deletedownloaded && -f $file_path ) {
                printf( "Deleting '%s'\n", $file_path );
                unlink($file_path);
            }

            if ( $checkdownload && -f $file_path ) {
                # The file is already there, no need to connect to a FTP
                # server.  This also means no file name globbing was
                # used (for globbing FTP URIs, we always need to connect
                # to a FTP site to see what files are there).

                printf( "File '%s' already exists\n", $file_path );
                push( @processed_files, $file_path );
                next;
            }

            printf( "Connecting to FTP host '%s'\n", $uri->host() );

            my $ftp = Net::FTP->new( $uri->host(), 'Debug' => 0 );
            if ( !defined($ftp) ) {
                printf( "==> Can not open FTP connection: %s\n",
                        $ftp->message() );
                return ();
            }

            if ( !$ftp->login( 'anonymous', '-anonymous@' ) ) {
                printf( "==> Can not log in on FTP host: %s\n",
                        $ftp->message() );
                return ();
            }

            if ( !$ftp->cwd( dirname( $uri->path() ) ) ) {
                printf( "== Can not change directory to '%s': %s\n",
                        dirname( $uri->path() ), $ftp->message() );
                return ();
            }

            foreach my $remote_file ( ( @{ $ftp->ls() } ) ) {
                if (
                     !match_glob( basename( $uri->path() ), $remote_file
                     ) )
                {
                    next;
                }

                $file_path =
                  catfile( $dest_dir, basename($remote_file) );

                if ( $deletedownloaded && -f $file_path ) {
                    printf( "Deleting '%s'\n", $file_path );
                    unlink($file_path);
                }

                if ( $checkdownload && -f $file_path ) {
                    printf( "File '%s' already exists\n", $file_path );
                } else {

                    if ( !-d dirname($file_path) ) {
                        printf( "Creating directory '%s'\n",
                                dirname($file_path) );
                        if ( !mkdir( dirname($file_path) ) ) {
                            printf(
                                "==> Can not create directory '%s': %s",
                                dirname($file_path), $! );
                            return ();
                        }
                    }

                    printf( "Fetching '%s' (size = %d)\n",
                            $remote_file, $ftp->size($remote_file) );
                    printf( "Local file is '%s'\n", $file_path );

                    $ftp->binary();
                    if ( !$ftp->get( $remote_file, $file_path ) ) {
                        printf( "==> Could not get '%s': %s\n",
                                basename( $uri->path() ),
                                $ftp->message() );
                        return ();
                    }
                } ## end else [ if ( $checkdownload &&...

                push( @processed_files, $file_path );

            } ## end foreach my $remote_file ( (...

        } elsif ( $uri->scheme() eq 'http' ) {
            # Deal with HTTP files.

            my $file_path =
              catfile( $dest_dir, basename( $uri->path() ) );

            if ( $deletedownloaded && -f $file_path ) {
                printf( "Deleting '%s'\n", $file_path );
                unlink($file_path);
            }

            if ( $checkdownload && -f $file_path ) {
                # The file is already there, no need to connect to a
                # HTTP server.

                printf( "File '%s' already exists\n", $file_path );
                push( @processed_files, $file_path );
                next;
            }

            if ( !-d dirname($file_path) ) {
                printf( "Creating directory '%s'\n",
                        dirname($file_path) );
                if ( !mkdir( dirname($file_path) ) ) {
                    printf( "==> Can not create directory '%s': %s",
                            dirname($file_path), $! );
                    return ();
                }
            }

            printf( "Connecting to HTTP host '%s'\n", $uri->host() );
            printf( "Fetching '%s'\n",                $uri->path() );

            if ( $checkdownload && -f $file_path ) {
                printf( "File '%s' already exists\n", $file_path );
            } else {

                printf( "Local file is '%s'\n", $file_path );

                my $ua = LWP::UserAgent->new();
                $ua->env_proxy();

                my $response = $ua->get( $uri->as_string(),
                                        ':content_file' => $file_path );

                if ( !$response->is_success() ) {
                    printf( "==> Could not get '%s': %s\n",
                            basename( $uri->path() ),
                            $response->content() );
                    return ();
                }
            }

            push( @processed_files, $file_path );

        } elsif ( $uri->schema() eq 'mysql' ) {
            # Just leave MySQL data untouched for now.
            push( @processed_files, $user_uri );
        } else {
            printf( "==> Unknown URI scheme '%s' in URI '%s'\n",
                    $uri->scheme(), $uri->as_string() );
            return ();
        }
    } ## end foreach my $user_uri (@user_uris)

    return ( wantarray() ? @processed_files : \@processed_files );
} ## end sub fetch_files

# Given a file name, returns a IO::Handle object.  If the file is
# gzipped, the handle will be to an unseekable stream coming out of a
# zcat pipe.  If the given file name doesn't correspond to an existing
# file, the routine will try to add '.gz' to the file name or to remove
# any .'Z' or '.gz' and try again.  Returns undef on failure and will
# write a warning to stderr.

sub get_filehandle
{
    my ($self, $file_name) = @_;

    my $io;

    my $alt_file_name = $file_name;
    $alt_file_name =~ s/\.(gz|Z)$//;

    if ( $alt_file_name eq $file_name ) {
        $alt_file_name .= '.gz';
    }

    if ( !-f $file_name ) {
        carp(   "File '$file_name' does not exist, "
              . "will try '$alt_file_name'" );
        $file_name = $alt_file_name;
    }

    if ( $file_name =~ /\.(gz|Z)$/ ) {
        # Read from zcat pipe
        $io = IO::File->new("zcat $file_name |")
          or carp("Can not open file '$file_name' with 'zcat'");
    } else {
        # Read file normally
        $io = IO::File->new($file_name)
          or carp("Can not open file '$file_name'");
    }

    if ( !defined $io ) { return undef }

    print "Reading from '$file_name'...\n";

    return $io;
}

# ------------------------------------------------------------------------------

sub new
{
    my ($proto) = @_;

    my $class = ref $proto || $proto;
    return bless {}, $class;
}

# --------------------------------------------------------------------------------
# Get source ID for a particular file; matches url field

sub get_source_id_for_filename {

  my ($self, $file) = @_;
  print STDERR "FILE $file\n" ; 
  my $sql = "SELECT s.source_id FROM source s, source_url su WHERE su.source_id=s.source_id AND su.url LIKE  '%/" . $file . "%'";
  my $sth = dbi()->prepare($sql);
  $sth->execute();
  my @row = $sth->fetchrow_array();
  my $source_id;
  if (@row) {
    $source_id = $row[0];
  } 
  else {
    if($file =~ /rna.fna/ or $file =~ /gpff/){
      $source_id = 3;
    }else{ 
      warn("Couldn't get source ID for file $file\n");
      $source_id = -1;
    }
  }
  

  return $source_id;

}

sub rename_url_file{
  return undef;
}

# Get species ID for a particular file; matches url field

sub get_species_id_for_filename {

  my ($self, $file) = @_;

  my $sql = "SELECT su.species_id FROM source_url su WHERE su.url LIKE  '%/" . $file . "%'";
  my $sth = dbi()->prepare($sql);
  $sth->execute();
  my @row = $sth->fetchrow_array();
  my $source_id;
  if (@row) {
    $source_id = $row[0];
  } else {
    warn("Couldn't get species ID for file $file\n");
    $source_id = -1;
  }

  return $source_id;

}

# --------------------------------------------------------------------------------
# Get source ID for a particular source name

sub get_source_id_for_source_name {
  
  my ($self, $source_name,$priority_desc) = @_;
  my $sql = "SELECT source_id FROM source WHERE LOWER(name)='" . lc($source_name) . "'";
  if(defined($priority_desc)){
    $sql .= " AND LOWER(priority_description)='".lc($priority_desc)."'";
  }
  my $sth = dbi()->prepare($sql);
  $sth->execute();
  my @row = $sth->fetchrow_array();
  my $source_id;
  if (@row) {
    $source_id = $row[0]; 
  } else {
    print STDERR "WARNING: There is no entity $source_name in the source-table of the xref database.\n" .
      "WARNING:. The external db name ($source_name) is hardcoded in the parser\n";
    warn("WARNING: Couldn't get source ID for source name $source_name\n");

    $source_id = -1;
  }
  return $source_id;
}



# --------------------------------------------------------------------------------
# Get a set of source IDs matching a source name pattern

sub get_source_ids_for_source_name_pattern {

  my ($self, $source_name) = @_;

  my $sql = "SELECT source_id FROM source WHERE upper(name) LIKE '%".uc($source_name)."%'";

  my $sth = dbi()->prepare($sql);
  my @sources;
  $sth->execute();
  while(my @row = $sth->fetchrow_array()){
    push @sources,$row[0];
  }
  $sth->finish;

  return @sources;

}

sub get_source_name_for_source_id {
  my ($self, $source_id) = @_;
  my $source_name;

  my $sql = "SELECT name FROM source WHERE source_id= '" . $source_id. "'";
  my $sth = dbi()->prepare($sql);
  $sth->execute();
  my @row = $sth->fetchrow_array();
  if (@row) {
    $source_name = $row[0]; 
  } else {
    print STDERR "WARNING: There is no entity with source-id  $source_id  in the source-table of the \n" .
      "WARNING: xref-database. The source-id and the name of the source-id is hard-coded in populate_metadata.sql\n" .
	"WARNING: and in the parser\n";
    warn("WARNING: Couldn't get source name for source ID $source_id\n");
    $source_name = -1;
  }
  return $source_name;
}









sub get_valid_xrefs_for_dependencies{
  my ($self, $dependent_name, @reverse_ordered_source_list) = @_;

  my %dependent_2_xref;


  my $sql = "select source_id from source where LOWER(name) =?";
  my $sth = dbi()->prepare($sql);
  my @dependent_sources;
  $sth->execute(lc($dependent_name));
  while(my @row = $sth->fetchrow_array()){
   push @dependent_sources,$row[0];
  }

  my @sources;
  foreach my $name (@reverse_ordered_source_list){
    $sth->execute(lc($name));
    while(my @row = $sth->fetchrow_array()){
      push @sources,$row[0];
    }
  }
  $sth->finish;

  $sql  = "select d.master_xref_id, x2.accession ";
  $sql .= "  from dependent_xref d, xref x1, xref x2 ";
  $sql .= "    where x1.xref_id = d.master_xref_id and";
  $sql .= "          x1.source_id=? and ";
  $sql .= "          x2.xref_id = d.dependent_xref_id and";
  $sql .= "          x2.source_id=? ";
  
  $sth = dbi()->prepare($sql);
  foreach my $d (@dependent_sources){
    foreach my $s (@sources){
       $sth->execute($s,$d);
       while(my @row = $sth->fetchrow_array()){
	 $dependent_2_xref{$row[1]} = $row[0];
       }
     }
  }
  return \%dependent_2_xref;
}

sub get_valid_xrefs_for_direct_xrefs{
  my ($self, $direct_name, @list) = @_;

  my %direct_2_xref;


  my $sql = "select source_id from source where name like ?";
  my $sth = dbi()->prepare($sql);
  my @direct_sources;
  $sth->execute($direct_name."%");
  while(my @row = $sth->fetchrow_array()){
    push @direct_sources,$row[0];
  }

  my @sources;
  foreach my $name (@list){
    $sth->execute($name);
    while(my @row = $sth->fetchrow_array()){
      push @sources,$row[0];
    }
  }
  $sth->finish;

  $sql  = "select d.general_xref_id, d.ensembl_stable_id, d.type, d.linkage_xref, x1.accession ";
  $sql .= "  from direct_xref d, xref x1 ";
  $sql .= "    where x1.xref_id = d.general_xref_id and";
  $sql .= "          x1.source_id=?";
   
  $sth = dbi()->prepare($sql);
  foreach my $d (@direct_sources){
    $sth->execute($d);
    while(my @row = $sth->fetchrow_array()){
      $direct_2_xref{$row[4]} = $row[0]."::".$row[1]."::".$row[2]."::".$row[3];
    }
  }

  return \%direct_2_xref;
}



sub get_valid_codes{

  my ($self,$source_name,$species_id) =@_;

  # First cache synonyms so we can quickly add them later
  my %synonyms;
  my $syn_sth = dbi()->prepare("SELECT xref_id, synonym FROM synonym");
  $syn_sth->execute();

  my ($xref_id, $synonym);
  $syn_sth->bind_columns(\$xref_id, \$synonym);
  while ($syn_sth->fetch()) {

    push @{$synonyms{$xref_id}}, $synonym;

  }

  my %valid_codes;
  my @sources;

  my $sql = "select source_id from source where upper(name) like '%".uc($source_name)."%'";
  my $sth = dbi()->prepare($sql);
  $sth->execute();
  while(my @row = $sth->fetchrow_array()){
    push @sources,$row[0];
  }
  $sth->finish;

  foreach my $source (@sources){
    $sql = "select accession, xref_id from xref where species_id = $species_id and source_id = $source";
    my $sth = dbi()->prepare($sql);
    $sth->execute();
    while(my @row = $sth->fetchrow_array()){
      $valid_codes{$row[0]} =$row[1];
      # add any synonyms for this xref as well
      foreach my $syn (@{$synonyms{$row[1]}}) {
	$valid_codes{$syn} = $row[1];
      }
    }
  }
  return \%valid_codes;
}

# --------------------------------------------------------------------------------



# --------------------------------------------------------------------------------



sub get_existing_mappings {

  my ($self, $from_source_name, $to_source_name, $species_id) =@_;

  my %mappings;

  my $from_source = $self->get_source_id_for_source_name($from_source_name);
  my $to_source = $self->get_source_id_for_source_name($to_source_name);

  my $sql = "SELECT dx.dependent_xref_id, x1.accession as dependent, dx.master_xref_id, x2.accession as master FROM dependent_xref dx, xref x1, xref x2 WHERE x1.xref_id=dx.dependent_xref_id AND x2.xref_id=dx.master_xref_id AND x2.source_id=? AND x1.source_id=? AND x1.species_id=? AND x2.species_id=?";

  my $sth = dbi()->prepare($sql);
  $sth->execute($to_source, $from_source, $species_id, $species_id);
  while(my @row = $sth->fetchrow_array()){
    $mappings{$row[1]} = $row[2];
    #print "mgi_to_uniprot{" . $row[1] . "} = " . $row[2] . "\n";
  }

  print "Got " . scalar(keys(%mappings)) . " $from_source_name -> $to_source_name mappings\n";

  return \%mappings;

}

# --------------------------------------------------------------------------------
# Upload xrefs to the database

sub upload_xref_object_graphs {
  my ($self, $rxrefs) = @_;

  my $dbi = dbi();
  print "count = ".$#$rxrefs."\n";

  if ($#$rxrefs > -1) {

    # remove all existing xrefs with same source ID(s)
#    $self->delete_by_source($rxrefs);

    # upload new ones
    print "Uploading xrefs\n";
    my $xref_sth = $dbi->prepare("INSERT INTO xref (accession,version,label,description,source_id,species_id) VALUES(?,?,?,?,?,?)");
    my $pri_insert_sth = $dbi->prepare("INSERT INTO primary_xref VALUES(?,?,?,?)");
    my $pri_update_sth = $dbi->prepare("UPDATE primary_xref SET sequence=? WHERE xref_id=?");
    my $syn_sth = $dbi->prepare("INSERT INTO synonym VALUES(?,?)");
    my $dep_sth = $dbi->prepare("INSERT INTO dependent_xref (master_xref_id, dependent_xref_id, linkage_annotation, linkage_source_id) VALUES(?,?,?,?)");
    my $xref_update_label_sth = $dbi->prepare("UPDATE xref SET label=? WHERE xref_id=?");
    my $xref_update_descr_sth = $dbi->prepare("UPDATE xref SET description=? WHERE xref_id=?");
    my $pair_sth = $dbi->prepare("INSERT INTO pairs VALUES(?,?,?)");

    local $xref_sth->{RaiseError}; # disable error handling here as we'll do it ourselves
    local $xref_sth->{PrintError};

    foreach my $xref (@{$rxrefs}) {
       my $xref_id=undef;
       if(!defined($xref->{ACCESSION})){
	 print "your xref does not have an accession-number,so it can't be stored in the database\n";
	 return undef;
       }
      # Create entry in xref table and note ID
      if(! $xref_sth->execute($xref->{ACCESSION},
			 $xref->{VERSION} || 0,
			 $xref->{LABEL},
			 $xref->{DESCRIPTION},
			 $xref->{SOURCE_ID},
			 $xref->{SPECIES_ID})){
	if(!defined($xref->{SOURCE_ID})){
	  print "your xref: $xref->{ACCESSION} does not have a source-id\n";
	  return undef;
	}
	$xref_id = insert_or_select($xref_sth, $dbi->err, $xref->{ACCESSION}, $xref->{SOURCE_ID}, $xref->{SPECIES_ID});
	$xref_update_label_sth->execute($xref->{LABEL},$xref_id) if (defined($xref->{LABEL}));
	$xref_update_descr_sth->execute($xref->{DESCRIPTION},$xref_id,) if (defined($xref->{DESCRIPTION}));
      }
      else{
	$xref_id = insert_or_select($xref_sth, $dbi->err, $xref->{ACCESSION}, $xref->{SOURCE_ID}, $xref->{SPECIES_ID});
      }


      # create entry in primary_xref table with sequence; if this is a "cumulative"
      # entry it may already exist, and require an UPDATE rather than an INSERT
      if(!(defined($xref_id) and $xref_id)){
	print STDERR "xref_id is not set for :\n$xref->{ACCESSION}\n$xref->{LABEL}\n$xref->{DESCRIPTION}\n$xref->{SOURCE_ID}\n";
      }
      if ( primary_xref_id_exists($xref_id) ) {
          $pri_update_sth->execute( $xref->{SEQUENCE}, $xref_id )
            or croak( $dbi->errstr() );
      } else {
	
      $pri_insert_sth->execute( $xref_id, $xref->{SEQUENCE},
          $xref->{SEQUENCE_TYPE},
          $xref->{STATUS} )
        or croak( $dbi->errstr() );
      }

      # if there are synonyms, add entries in the synonym table
      foreach my $syn ( @{ $xref->{SYNONYMS} } ) {
          $syn_sth->execute( $xref_id, $syn )
            or croak( $dbi->errstr() . "\n $xref_id\n $syn\n" );
      } # foreach syn

      # if there are dependent xrefs, add xrefs and dependent xrefs for them
      foreach my $depref (@{$xref->{DEPENDENT_XREFS}}) {

	my %dep = %$depref;

	$xref_sth->execute($dep{ACCESSION},
			   $dep{VERSION} || 0,
			   $dep{LABEL},
			   "",
			   $dep{SOURCE_ID},
			   $xref->{SPECIES_ID});

	my $dep_xref_id = insert_or_select($xref_sth, $dbi->err, $dep{ACCESSION}, $dep{SOURCE_ID}, $xref->{SPECIES_ID});

	if($dbi->err){
	  print STDERR "dbi\t$dbi->err \n$dep{ACCESSION} \n $dep{SOURCE_ID} \n";
	}
	if(!defined($dep_xref_id) || $dep_xref_id ==0 ){
	  print STDERR "acc = $dep{ACCESSION} \nlink = $dep{LINKAGE_SOURCE_ID} \n".$dbi->err."\n";
	  print STDERR "source = $dep{SOURCE_ID}\n";
	}
        $dep_sth->execute( $xref_id, $dep_xref_id,
            $dep{LINKAGE_ANNOTATION},
            $dep{LINKAGE_SOURCE_ID} )
          or croak( $dbi->errstr() );
      }	 # foreach dep
       
       if(defined($xref_id) and defined($xref->{PAIR})){
	 $pair_sth->execute($xref->{SOURCE_ID},$xref->{ACCESSION},$xref->{PAIR});
       }				
       
              
       $xref_sth->finish() if defined $xref_sth;
       $pri_insert_sth->finish() if defined $pri_insert_sth;
       $pri_update_sth->finish() if defined $pri_update_sth;
       
     }  # foreach xref

  }
  return 1;
}

sub upload_direct_xrefs{
  my ($self, $direct_xref)  = @_;
  for my $dr(@$direct_xref) {
    # print "having now direct-XREF : $dr->{ENSEMBL_STABLE_ID} \n" ;
    my $general_xref_id = get_xref_id_by_accession_and_source($dr->{ACCESSION},$dr->{SOURCE_ID});
    if ($general_xref_id){
      # print "direct_xref:\n$general_xref_id\n$dr->{ENSEMBL_STABLE_ID}\n$dr->{ENSEMBL_TYPE}\t$dr->{LINKAGE_XREF}\n\n";
      $self->add_direct_xref($general_xref_id, $dr->{ENSEMBL_STABLE_ID},$dr->{ENSEMBL_TYPE},$dr->{LINKAGE_XREF});
    }
  }
}



# --------------------------------------------------------------------------------
# Get & cache a hash of all the source names for dependent xrefs (those that are
# in the source table but don't have an associated URL etc)

sub get_dependent_xref_sources {

  my $self = shift;

  if (!%dependent_sources) {

    my $dbi = dbi();
    my $sth = $dbi->prepare("SELECT name,source_id FROM source");
    $sth->execute() or croak( $dbi->errstr() );
    while(my @row = $sth->fetchrow_array()) {
      my $source_name = $row[0];
      my $source_id = $row[1];
      $dependent_sources{$source_name} = $source_id;
    }
  }

  return %dependent_sources;

}

# --------------------------------------------------------------------------------
# Get & cache a hash of all the species IDs & taxonomy IDs.

sub taxonomy2species_id {

  my $self = shift;

  if (!%taxonomy2species_id) {

    my $dbi = dbi();
    my $sth = $dbi->prepare("SELECT species_id, taxonomy_id FROM species");
    $sth->execute() or croak( $dbi->errstr() );
    while(my @row = $sth->fetchrow_array()) {
      my $species_id = $row[0];
      my $taxonomy_id = $row[1];
      $taxonomy2species_id{$taxonomy_id} = $species_id;
    }
  }

  return %taxonomy2species_id;

}

# --------------------------------------------------------------------------------
# Get & cache a hash of all the species IDs & species names.

sub name2species_id {
    my $self = shift;

    if ( !%name2species_id ) {

        my $dbi = dbi();
        my $sth = $dbi->prepare("SELECT species_id, name FROM species");
        $sth->execute() or croak( $dbi->errstr() );
        while ( my @row = $sth->fetchrow_array() ) {
            my $species_id = $row[0];
            my $name       = $row[1];
            $name2species_id{$name} = $species_id;
        }

        # Also populate the hash with all the aliases.
        $sth = $dbi->prepare("SELECT species_id, aliases FROM species");
        $sth->execute() or croak( $dbi->errstr() );
        while ( my @row = $sth->fetchrow_array() ) {
            my $species_id = $row[0];
            foreach my $name ( split /,\s*/, $row[1] ) {
                if ( exists $name2species_id{$name} ) {
                    warn "Ambigous species alias: "
                      . "$name (id = $species_id)\n";
                } else {
                    $name2species_id{$name} = $species_id;
                }
            }
        }

    } ## end if ( !%name2species_id)

    return %name2species_id;
} ## end sub name2species_id

# --------------------------------------------------------------------------------
# Update a row in the source table

sub update_source
{
    my ( $dbi, $source_url_id, $checksum, $file_name ) = @_;

    my $file = IO::File->new($file_name)
      or croak("Failed to open file '$file_name'");

    my $file_date =
      POSIX::strftime( '%Y%m%d%H%M%S',
        localtime( [ $file->stat() ]->[9] ) );

    $file->close();

    my $sql =
        "UPDATE source_url SET checksum='$checksum', "
      . "file_modified_date='$file_date', "
      . "upload_date=NOW() "
      . "WHERE source_url_id=$source_url_id";

    # The release is set by the individual parser by calling the
    # inherited set_release() method.

    $dbi->prepare($sql)->execute() || croak( $dbi->errstr() );
}


# --------------------------------------------------------------------------------

sub dbi
{
    my $self = shift;

    if ( !defined $dbi ) {
        my $connect_string =
          sprintf( "dbi:mysql:host=%s;port=%s;database=%s",
            $host, $port, $dbname );

        $dbi =
          DBI->connect( $connect_string, $user, $pass,
            { 'RaiseError' => 1 } )
          or croak( "Can't connect to database: " . $DBI::errstr );
    }

    return $dbi;
}

# --------------------------------------------------------------------------------

# Compute a checksum of a file.  This checksum is not a straight MD5
# hex digest, but instead the file size combined with the first six
# characters of the MD5 hex digest.  This is to save space.

sub md5sum
{
    my $file = shift;

    if ( !open( FILE, $file ) ) { return undef }
    binmode(FILE);

    my $checksum = sprintf( "%s/%d",
        substr( Digest::MD5->new()->addfile(*FILE)->hexdigest(), 0, 6 ),
        [ stat FILE ]->[7] );

    close(FILE);

    return $checksum;
}

# --------------------------------------------------------------------------------

sub get_xref_id_by_accession_and_source {

  my ($acc, $source_id, $species_id ) = @_;

  my $dbi = dbi();

  my $sql = '
SELECT xref_id FROM xref WHERE accession=? AND source_id=?';
  if( $species_id ){ $sql .= ' AND species_id=?' }

  my $sth = $dbi->prepare( $sql );

  $sth->execute( $acc, $source_id, ( $species_id ? $species_id : () ) )
    or croak( $dbi->errstr() );

  my @row = $sth->fetchrow_array();
  my $xref_id = $row[0];

  return $xref_id;

}

# --------------------------------------------------------------------------------
# If there was an error, an xref with the same acc & source already exists.
# If so, find its ID, otherwise get ID of xref just inserted

sub insert_or_select {

  my ($sth, $error, $acc, $source, $species) = @_;

  my $id;

  # TODO - check for specific error code rather than for just any error
  if ($error) {

    $id = get_xref_id_by_accession_and_source($acc, $source, $species);
#    print STDERR "Got existing xref id " . $id . " for " . $acc . " " . $source . "\n";
	
  } else {
	
    $id = $sth->{'mysql_insertid'};
	
  }

  return $id;

}

# --------------------------------------------------------------------------------

sub primary_xref_id_exists {

  my $xref_id = shift;

  my $exists = 0;

  my $dbi = dbi();
  my $sth = $dbi->prepare("SELECT xref_id FROM primary_xref WHERE xref_id=?");
  $sth->execute($xref_id) or croak( $dbi->errstr() );
  my @row = $sth->fetchrow_array();
  my $result = $row[0];
  $exists = 1 if (defined $result);

  return $exists;

}

# --------------------------------------------------------------------------------

# delete all xrefs & related objects

sub delete_by_source {

  my $self =shift;
  my $xrefs = shift;

  # SQL for deleting stuff
  # Note this SQL only works on MySQL version 4 and above

  #Remove direct xrefsbased on source
  my $direct_sth = $dbi->prepare("DELETE FROM direct_xref USING xref, direct_xref WHERE xref.xref_id=direct_xref.general_xref_id AND xref.source_id=?");
  
  #remove Pairs fro source
  my $pairs_sth = $dbi->prepare("DELETE FROM pairs WHERE source_id=?");

  # Remove dependent_xrefs and synonyms based on source of *xref*
  my $syn_sth = $dbi->prepare("DELETE FROM synonym USING xref, synonym WHERE xref.xref_id=synonym.xref_id AND xref.source_id=?");
  my $dep_sth = $dbi->prepare("DELETE FROM dependent_xref USING xref, dependent_xref WHERE xref.xref_id=dependent_xref.master_xref_id AND xref.source_id=?");

  # xrefs and primary_xrefs are straightforward deletes
  my $xref_sth = $dbi->prepare("DELETE FROM xref, primary_xref USING xref, primary_xref WHERE source_id=? AND primary_xref.xref_id = xref.xref_id");
#  my $p_xref_sth = $dbi->prepare("DELETE FROM primary_xref WHERE source_id=?");

  # xrefs may come from more than one source (e.g. UniProt/SP/SPtr)
  # so find all sources first
  my %source_ids;
  foreach my $xref (@$xrefs) {
    my $xref_source = $xref->{SOURCE_ID};
    $source_ids{$xref_source} = 1;
  }

  # now delete them
  foreach my $source (keys %source_ids) {
    print "Deleting pairs with source ID $source \n";
    $pairs_sth->execute($source);
    print "Deleting direct xrefs with source ID $source \n";
    $direct_sth->execute($source);
    print "Deleting synonyms of xrefs with source ID $source \n";
    $syn_sth->execute($source);
    print "Deleting dependent xrefs of xrefs with source ID $source \n";
    $dep_sth->execute($source);
    print "Deleting primary xrefs with source ID $source \n";
#    $p_xref_sth->execute($source);
    print "Deleting xrefs with source ID $source \n";
    $xref_sth->execute($source);
  }

  $syn_sth->finish() if defined $syn_sth;
  $dep_sth->finish() if defined $dep_sth;
  $xref_sth->finish() if defined $xref_sth;
#  $p_xref_sth->finish() if defined $p_xref_sth;

}

# --------------------------------------------------------------------------------

sub validate_sources {

  my @sources = @_;

  my $dbi = dbi();
  my $sth = $dbi->prepare("SELECT * FROM source WHERE LOWER(name)=?");

  foreach my $source (@sources) {

    my $rv = $sth->execute(lc($source));
    if ( $rv > 0 ) {
      print "Source $source is valid\n";
    } else {
      print "\nSource $source is not valid; valid sources are:\n";
      show_valid_sources();
      return 0;
    }

  }

  return 1;

}

# --------------------------------------------------------------------------------

sub show_valid_sources() {

  my $dbi = dbi();
  my $sth = $dbi->prepare("SELECT name FROM source WHERE download='Y'");

  $sth->execute();
  while (my @row = $sth->fetchrow_array()) {
    print $row[0] . "\n";
  }

}

# --------------------------------------------------------------------------------

sub validate_species {
  my @species = @_;
  my @species_ids;

  my $dbi = dbi();
  my $sth = $dbi->prepare("SELECT species_id, name FROM species WHERE LOWER(name)=? OR LOWER(aliases) LIKE ?");
  my ($species_id, $species_name);

  foreach my $sp (@species) {

    $sth->execute(lc($sp), "%" . lc($sp) . "%");
    $sth->bind_columns(\$species_id, \$species_name);
    if (my @row = $sth->fetchrow_array()) {
      print "Species $sp is valid (name = " . $species_name . ", ID = " . $species_id . ")\n";
      push @species_ids, $species_id;
    } else {
      print "Species $sp is not valid; valid species are:\n";
      show_valid_species();
      exit(1);
    }
  }
  return @species_ids;
}

# --------------------------------------------------------------------------------

sub show_valid_species() {

  my $dbi = dbi();
  my $sth = $dbi->prepare("SELECT name, aliases FROM species");

  $sth->execute();
  while (my @row = $sth->fetchrow_array()) {
    print $row[0] . " (aliases: " . $row[1] . ")\n";
  }

}

sub get_taxonomy_from_species_id{
  my ($self,$species_id) = @_;
  my %hash;

  my $dbi = dbi();
  my $sth = $dbi->prepare("SELECT taxonomy_id FROM species WHERE species_id = $species_id");
  $sth->execute() or croak( $dbi->errstr() );
  while(my @row = $sth->fetchrow_array()) {
    $hash{$row[0]} = 1;
  }   
  $sth->finish;
  return \%hash;
}

sub get_direct_xref{
  my ($self,$stable_id,$type,$link) = @_;

  my $direct_sth;
  if(!defined($direct_sth)){
    my $sql = "select general_xref_id from direct_xref d where ensembl_stable_id = ? and type = ?  and linkage_xref= ?";
    $direct_sth = $dbi->prepare($sql);  
  }
  
  $direct_sth->execute( $stable_id, $type, $link )
    or croak( $dbi->errstr() );
  if(my @row = $direct_sth->fetchrow_array()) {
    return $row[0];
  }   
  return undef;
}

sub get_xref{
  my ($self,$acc,$source) = @_;

  if(!defined($get_xref_sth)){
    my $sql = "select xref_id from xref where accession = ? and source_id = ?";
    $get_xref_sth = $dbi->prepare($sql);  
  }
  
  $get_xref_sth->execute( $acc, $source ) or croak( $dbi->errstr() );
  if(my @row = $get_xref_sth->fetchrow_array()) {
    return $row[0];
  }   
  return undef;
}

sub add_xref {

  my ($self,$acc,$version,$label,$description,$source_id,$species_id) = @_;

  if(!defined($add_xref_sth)){
    $add_xref_sth = dbi->prepare("INSERT INTO xref (accession,version,label,description,source_id,species_id) VALUES(?,?,?,?,?,?)");
  }
  $add_xref_sth->execute(
      $acc, $version || 0, $label,
      $description, $source_id, $species_id
  ) or croak("$acc\t$label\t\t$source_id\t$species_id\n");

  return $add_xref_sth->{'mysql_insertid'};

}


sub add_to_xrefs{
  my ($self,$master_xref,$acc,$version,$label,$description,$linkage,$source_id,$species_id) = @_;

  if(!defined($add_xref_sth)){
    $add_xref_sth = dbi->prepare("INSERT INTO xref (accession,version,label,description,source_id,species_id)".
				 " VALUES(?,?,?,?,?,?)");
  }
  if(!defined($add_dependent_xref_sth)){
    $add_dependent_xref_sth = dbi->prepare("INSERT INTO dependent_xref VALUES(?,?,?,?)");
  }
  
  my $dependent_id = $self->get_xref($acc, $source_id);
  if(!defined($dependent_id)){
    $add_xref_sth->execute(
        $acc, $version || 0, $label,
        $description, $source_id, $species_id
    ) or croak("$acc\t$label\t\t$source_id\t$species_id\n");
  }
  $dependent_id = $self->get_xref($acc, $source_id);
  if(!defined($dependent_id)){
    croak("$acc\t$label\t\t$source_id\t$species_id\n");
  }
  if ($master_xref == 48955) {
    print "$master_xref\t$acc\t$dependent_id\t$linkage\t$source_id\n";
  }
  $add_dependent_xref_sth->execute( $master_xref, $dependent_id, $linkage,
      $source_id )
    or croak("$master_xref\t$dependent_id\t$linkage\t$source_id");

}

sub add_to_syn_for_mult_sources{
  my ($self, $acc, $sources, $syn) = @_;

  if(!defined($add_synonym_sth)){
    $add_synonym_sth =  $dbi->prepare("INSERT INTO synonym VALUES(?,?)");
  }
  my $found =0;
  foreach my $source_id (@$sources){
    my $xref_id = $self->get_xref($acc, $source_id);
    if(defined($xref_id)){
      $add_synonym_sth->execute( $xref_id, $syn )
        or croak( $dbi->errstr() . "\n $xref_id\n $syn\n" );
      $found = 1;
    }
  }
    #if ( !$found ) {
    #    croak(  "Could not find acc $acc in xref table for sources"
    #          . join( ", ", @$sources )
    #          . "\n" );
    #}
}


sub add_to_syn{
  my ($self, $acc, $source_id, $syn) = @_;

  if(!defined($add_synonym_sth)){
    $add_synonym_sth =  $dbi->prepare("INSERT INTO synonym VALUES(?,?)");
  }
  my $xref_id = $self->get_xref($acc, $source_id);
  if(defined($xref_id)){
    $add_synonym_sth->execute( $xref_id, $syn )
      or croak( $dbi->errstr() . "\n $xref_id\n $syn\n" );
  }
  else {
      croak(  "Could not find acc $acc in "
            . "xref table source = $source_id\n" );
  }
}

# --------------------------------------------------------------------------------
# Add a single record to the direct_xref table.
# Note that an xref must already have been added to the xref table (xref_id passed as 1st arg)

sub add_direct_xref {

  my ($self, $general_xref_id, $ensembl_stable_id, $ensembl_type, $linkage_type) = @_;

  $add_direct_xref_sth = dbi->prepare("INSERT INTO direct_xref VALUES(?,?,?,?)") if (!defined($add_direct_xref_sth));

  $add_direct_xref_sth->execute($general_xref_id, $ensembl_stable_id, $ensembl_type, $linkage_type);

}

# ------------------------------------------------------------------------------

# Remove potentially problematic characters from string used as file or
# directory names.

sub sanitise {
    my $str = shift;
    $str =~ tr[/:][]d;
    return $str;
}

# ------------------------------------------------------------------------------

# Create database if required. Assumes sql/table.sql and sql/populate_metadata.sql
# are present.

sub create {

  my ($host, $port, $user, $pass, $dbname, $sql_dir,$drop_db ) = @_;

  my $dbh = DBI->connect( "DBI:mysql:host=$host:port=$port", $user, $pass,
                          {'RaiseError' => 1});

  # check to see if the database already exists
  my %dbs = map {$_->[0] => 1} @{$dbh->selectall_arrayref('SHOW DATABASES')};

  if ($dbs{$dbname}) {

    if ( $drop_db ) {     
	$dbh->do( "DROP DATABASE $dbname" );
	print "Database $dbname dropped\n" ; 
    }
  
    if ( $create && !$drop_db ) {
      print "WARNING: about to drop database $dbname on $host:$port; yes to confirm, otherwise exit: ";
      $| = 1; # flush stdout
      my $p = <STDIN>;
      chomp $p;
      if ($p eq "yes") {
	$dbh->do( "DROP DATABASE $dbname" );
	print "Removed existing database $dbname\n";
      } else {
	print "$dbname NOT removed\n";
	exit(1);
      }
    } elsif ( !$create) {
      croak(  "Database $dbname already exists. "
            . "Use -create option to overwrite it." );
    }
  }

  $dbh->do( "CREATE DATABASE " . $dbname );

  print "Creating $dbname from "
    . catfile( $sql_dir, 'sql', 'table.sql' ), "\n";
  if ( !-e catfile( $sql_dir, 'sql', 'table.sql' ) ) {
    croak( "Cannot open  " . catfile( $sql_dir, 'sql', 'table.sql' ) );
  }
  my $cmd = "mysql -u $user -p'$pass' -P $port -h $host $dbname < "
    . catfile( $sql_dir, 'sql', 'table.sql' );
  system($cmd) == 0 or die( "Cannot run the following (exit $?):\n$cmd\n" );

  print "Populating metadata in $dbname from ".$sql_dir."sql/populate_metadata.sql\n";
  if ( !-e catfile( $sql_dir, 'sql', 'populate_metadata.sql' ) ) {
    croak( "Cannot open "
           . catfile( $sql_dir, 'sql', 'populate_metadata.sql' ) );
  }
  $cmd = "mysql -u $user -p'$pass' -P $port -h $host $dbname < "
    . catfile( $sql_dir, 'sql', 'populate_metadata.sql' );
  system($cmd) == 0 or die( "Cannot run the following (exit $?):\n$cmd\n" );
}

sub get_label_to_accession{
  my ($self, $name) = @_;
  my %hash1=();

  my $dbi = dbi();
  my $sql = "select xref.accession, xref.label from xref, source where source.name like '$name%' and xref.source_id = source.source_id";
  my $sub_sth = dbi->prepare($sql);    

  $sub_sth->execute();
  while(my @row = $sub_sth->fetchrow_array()) {
    $hash1{$row[1]} = $row[0];
  }   	  
  return \%hash1;
}


sub get_accession_from_label{
  my ($self, $name) = @_;
  
  my $dbi = dbi();
  my $sql = "select xref.accession from xref where xref.label like '$name'";
  my $sub_sth = dbi->prepare($sql);    
  
  $sub_sth->execute();
  while(my @row = $sub_sth->fetchrow_array()) {
    return $row[0];
  }   	  
  return undef;
  
}

sub get_sub_list{
  my ($self, $name) = @_;
  my @list=();

  my $dbi = dbi();
  my $sql = "select xref.accession from xref where xref.accession like '$name%'";
  my $sub_sth = dbi->prepare($sql);    

  $sub_sth->execute();
  while(my @row = $sub_sth->fetchrow_array()) {
    push @list, $row[0];
  }   	  
  return @list;
}

# --------------------------------------------------------------------------------

# Set release for a source.

sub set_release
{
    my $self = shift;
    my ( $source_id, $release ) = @_;

    my $dbi = dbi();

    my $sth =
      $dbi->prepare(
        "UPDATE source SET source_release=? WHERE source_id=?");

    print "Setting release to '$release' for source ID '$source_id'\n";

    $sth->execute( $release, $source_id );
}

# --------------------------------------------------------------------------------
1;

