# EnsEMBL External object reference reading writing adaptor for mySQL
#
# Copyright EMBL-EBI 2001
#
# Author: Arne Stabenau
# 
# Date : 06.03.2001
#

=head1 NAME

Bio::EnsEMBL::DBSQL::DBEntryAdaptor - 
MySQL Database queries to load and store external object references.

=head1 SYNOPSIS

=head1 CONTACT

  Arne Stabenau: stabenau@ebi.ac.uk
  Ewan Birney  : birney@ebi.ac.uk

=head1 APPENDIX

=cut

;

package Bio::EnsEMBL::DBSQL::DBEntryAdaptor;

use Bio::EnsEMBL::DBSQL::BaseAdaptor;
use Bio::EnsEMBL::DBSQL::DBAdaptor;
use Bio::EnsEMBL::DBEntry;


use vars qw(@ISA);
use strict;

@ISA = qw( Bio::EnsEMBL::DBSQL::BaseAdaptor );

sub fetch_by_dbID {
  my ($self, $dbID ) = @_;
  
  my $sth = $self->prepare( "
    SELECT Xref.xrefId, Xref.dbprimary_id,
           Xref.version, Xref.description,
           exDB.db_name, exDB.release,
           exDB.url_pattern
      FROM Xref, externalDB exDB
     WHERE Xref.xrefId = $dbID
       AND Xref.externalDBId = exDb.externalDBId 
   " );

  $sth->execute();
  my ( $refID, $dbprimaryId, $version, $desc, $dbname, $release, $url ) =
    $sth->fetchrow_array();

  if( ! defined $refID ) {
    return undef;
  }

  my $exDB = Bio::EnsEMBL::DBEntry->new
    ( -adaptor => $self,
      -dbID => $dbID,
      -primary_id => $dbprimaryId,
      -version => $version,
      -release => $release,
      -dbname => $dbname );
  
  if( $desc ) {
    $exDB->description( $desc );
  }

  if( $url ) {
    $exDB->urlPattern( $url );
  }

  my $sth = $self->prepare( "
    SELECT synonym 
      FROM externalSynonym
     WHERE xrefId = $dbID
  " );
  $sth->execute();
  
  while( my ($synonym) = $sth->fetchrow_array() ) {
    $exDB->add_synonym( $synonym );
  }

  return $exDB;
}


sub store {
  my ( $self, $exObj, $ensObject, $ensType ) = @_;

  # $self->throw( "Sorry, store not yet supported" );
  my $dbUnknown;

  # check if db exists
  # urlPattern dbname release
  my $sth = $self->prepare( "
     SELECT externalDBId
       FROM externalDB
      WHERE db_name = ?
        AND release = ?
    " );
  $sth->execute( $exObj->dbname(), $exObj->release() );

  my $dbRef;

  if(  ($dbRef) =  $sth->fetchrow_array() ) {
    
  } else {
    # store it, get dbID for that
    $sth = $self->prepare( "
       INSERT INTO externalDB 
       SET db_name = ?,
           release = ?,
           url_pattern = ?
     " );
    $sth->execute( $exObj->dbname(), $exObj->release(),
 		   $exObj->url_pattern() );
    
    $dbUnknown = 1;
    $sth = $self->prepare( "
       SELECT LAST_INSERT_ID()
     " );
    $sth->execute();
    ( $dbRef ) = $sth->fetchrow_array();
    if( ! defined $dbRef ) {
      $self->throw( "Database entry failed." );
    }
  }

  my $dbX;
  
  if( ! $dbUnknown ) {
    $sth = $self->prepare( "
       SELECT xrefId
         FROM Xref
        WHERE externalDBId = ?
          AND dbprimary_id = ?
          AND version = ?
     " );
    $sth->execute( $dbRef, $exObj->primary_id(), 
		   $exObj->version() );
    ( $dbX ) = $sth->fetchrow_array();
  } else {
    # dont check for existence
  }

  if( ! defined $dbX ) {

    $sth = $self->prepare( "
      INSERT INTO Xref 
       SET dbprimary_id = ?,
           version = ?,
           description = ?,
           externalDBId = $dbRef
     " );
    $sth->execute( $exObj->primary_id(), $exObj->version(),
		   $exObj->description());

    $sth = $self->prepare( "
      SELECT LAST_INSERT_ID()
    " );
    $sth->execute();
    ( $dbX ) = $sth->fetchrow_array();

    # synonyms

    my @synonyms = $exObj->get_synonyms();
    foreach my $syn ( @synonyms ) {
      $sth = $self->prepare( "
        INSERT INTO externalSynonym
         SET xrefId = $dbX,
            synonym = '$syn'
      " );
      $sth->execute();
    }
  }
  
  $sth = $self->prepare( "
   INSERT INTO objectXref
     SET xrefId = $dbX,
         ensembl_object_type = ?,
         ensembl_id = ?
  " );
  $sth->execute( $ensType, $ensObject );

  $exObj->dbID( $dbX );
  $exObj->adaptor( $self );

  return $dbX;
}

sub fetch_by_gene {
  my ( $self, $geneId ) = @_;
  return $self->_fetch_by_EnsObject_type( $geneId, 'Gene' );
}

sub fetch_by_rawContig {
  my ( $self, $rawContigId ) = @_;
  return $self->_fetch_by_EnsObject_type( $rawContigId, 'RawContig' );
}

sub fetch_by_transcript {
  my ( $self, $trscId ) = @_;
  return $self->_fetch_by_EnsObject_type( $trscId, 'Transcript' );
}

sub fetch_by_translation {
  my ( $self, $trslId ) = @_;
  return $self->_fetch_by_EnsObject_type( $trslId, 'Translation' );
}


sub _fetch_by_EnsObject_type {
  my ( $self, $ensObj, $ensType ) = @_;
  my @out;

  my $sth = $self->prepare( "
    SELECT Xref.xrefId, Xref.dbprimary_id,
           Xref.version, Xref.description,
           exDB.db_name, exDB.release,
           exDB.url_pattern
      FROM Xref, externalDB exDB, objectXref oxr 
     WHERE Xref.xrefId = oxr.xrefId
       AND Xref.externalDBId = exDB.externalDBId 
       AND oxr.ensembl_id = '$ensObj'
       AND oxr.ensembl_object_type = '$ensType'
   " );

  $sth->execute();
  while ( my $arrRef = $sth->fetchrow_arrayref() ) {
    my ( $refID, $dbprimaryId, $version, $desc, $dbname, $release, $url ) =
      @$arrRef;;

    my $exDB = Bio::EnsEMBL::DBEntry->new
      ( -adaptor => $self,
	-dbID => $refID,
	-primary_id => $dbprimaryId,
	-version => $version,
	-release => $release,
	-dbname => $dbname );
  
    if( $desc ) {
      $exDB->description( $desc );
    }

    if( $url ) {
      $exDB->urlPattern( $url );
    }

    my $sth = $self->prepare( "
      SELECT synonym 
        FROM externalSynonym
       WHERE xrefId = $refID
    " );
    $sth->execute();
  
    while( my ($synonym) = $sth->fetchrow_array() ) {
      $exDB->add_synonym( $synonym );
    }
    push( @out, $exDB );
  }

  return @out;
}


# creates all tables for this adaptor
# if they exist they are emptied and newly created
sub create_tables {
  my $self = shift;

  my $sth = $self->prepare( "drop table if exists objectXref, Xref, externalDescription, externalSynonym, externalDB" );
  $sth->execute();

  $sth = $self->prepare( qq{
     CREATE TABLE objectXref(
       ensembl_id VARCHAR(40) not null, 
       ensembl_object_type ENUM( 'RawContig', 'Transcript', 'Gene', 'Translation' ) not null,
       xrefId INT not null,
       PRIMARY KEY( ensembl_object_type, ensembl_id, xrefId ),
       KEY xrefIdx( xrefId, ensembl_object_type, ensembl_id )
     )
   } );
  $sth->execute();
  $sth = $self->prepare( qq{
     CREATE TABLE Xref(
         xrefId INT not null auto_increment,
         externalDBId int not null,
         dbprimary_id VARCHAR(40) not null,
         version VARCHAR(10),
	 description VARCHAR(255),
         PRIMARY KEY( xrefId ),
         KEY idIdx( dbprimary_id ))
   } );

  $sth->execute();

  $sth = $self->prepare( qq{
     CREATE TABLE externalSynonym(
         xrefId INT not null,
         synonym VARCHAR(40) not null,
         PRIMARY KEY( xrefId, synonym ),
	 KEY nameIdx( synonym )) 
   } );
  $sth->execute();

  $sth = $self->prepare( qq{
     CREATE TABLE externalDB(
         externalDBId INT not null auto_increment,
         db_name VARCHAR(40) not null,
	 release VARCHAR(40),
         url_pattern VARCHAR(255),
         PRIMARY KEY( externalDBId ) ) 
   } );
  $sth->execute();
}


1;


__END__


# remove the tables from database
sub delete_tables {
}

# check if tables exist
sub exists_tables {
}

ObjectXref
=============
ensembl_id varchar, later int
ensembl_object_type  enum 
xrefId int
primary key (ensembl_id,ensembl_object_type,xrefId) 


Xref
=================
xrefId int (autogenerated) 
externalDBId int
dbprimary_id  varchar
version varchar

primary key (xrefId)

ExternalDescription
=======================
xrefId int
description varchar (256)

primary key (xrefId)

ExternalSynonym
=================
xrefId int
synonym varchar

primary key (external_id,synonym)


ExternalDB
===================
externalDBId int
db_name varchar
release varchar
url_pattern varchar

