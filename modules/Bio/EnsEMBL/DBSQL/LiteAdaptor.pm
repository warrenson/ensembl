# EnsEMBL Gene reading writing adaptor for mySQL
#
# Copyright EMBL-EBI 2001
#
# Author: James Smith
#

=head1 NAME

Bio::EnsEMBL::DBSQL::LiteAdaptor - MySQL Database queries to generate and store gens.

=head1 SYNOPSIS

=head1 CONTACT

  Arne Stabenau: stabenau@ebi.ac.uk
  James Smith  : js5@sanger.ac.uk

=head1 APPENDIX

=cut


package Bio::EnsEMBL::DBSQL::LiteAdaptor;
use strict;
use Bio::EnsEMBL::DBSQL::BaseAdaptor;
use Bio::EnsEMBL::DBSQL::DBAdaptor;
use Bio::Annotation::DBLink;
use vars '@ISA';

@ISA = ( 'Bio::EnsEMBL::DBSQL::BaseAdaptor' );

sub new {
    my ($class,$dbobj) = @_;

    my $self = {};
    bless $self,$class;

    if( !defined $dbobj || !ref $dbobj ) {
        $self->throw("Don't have a db [$dbobj] for new adaptor");
    }

    $self->db($dbobj);

    $self->{'_lite_db_name'} = $dbobj->{'_lite_db_name'};
    return $self;
}

#sub db {
#    my ($self, $arg) = @_;
#    $self->{'_db'} = $arg if ($arg);
#    return($self->{'_db'});
#}

sub fetch_virtualtranscripts_start_end {
    my ( $self, $chr, $vc_start, $vc_end, $database ) =@_;
    my $_db_name = $self->{'_lite_db_name'};
    $database      ||= 'ensembl';
    my $cache_name = "_$database"."_vtrans_cache_$chr"."_$vc_start"."_$vc_end";
    return $self->{$cache_name} if( $self->{$cache_name} );
    my $sth = $self->prepare(
        "select transcript_id, transcript_name, translation_name, gene_name,
                chr_start, chr_end, chr_strand, external_name, external_db,
                exon_structure, type
           from $_db_name.www_transcript
          where chr_name = ? and chr_start <= ? and chr_start >= ? and
                chr_end >= ? and db = ?"
    );
    
    eval {
        $sth->execute( "$chr", $vc_end, $vc_start-3000000, $vc_start, $database );
    };
    return [] if($@);
    my @transcripts;
    while( my $row = $sth->fetchrow_arrayref() ) {
        push @transcripts, {
            'transcript'=> $row->[0],
            'stable_id' => $row->[1],
            'translation'=> $row->[2],
            'gene'      => $row->[3],
            'chr_start' => $row->[4],
            'chr_end'   => $row->[5],
            'start'     => $row->[4]-$vc_start+1,
            'end'       => $row->[5]-$vc_start+1,
            'strand'    => $row->[6],
            'synonym'   => $row->[7],
            'db'        => $row->[8],
            'exon_structure' => [ split ':', $row->[9] ],
            'type'      => $row->[10]
        };
    }
    return $self->{$cache_name} = \@transcripts;
    return \@transcripts
}

sub fetch_virtualtranscripts_coding_start_end {
    my ( $self, $chr, $vc_start, $vc_end, $database ) =@_;
    my $_db_name = $self->{'_lite_db_name'};
    $database      ||= 'ensembl';
    my $cache_name = "_$database"."_vtrans_cache_$chr"."_$vc_start"."_$vc_end";
    return $self->{$cache_name} if( $self->{$cache_name} );
    my $sth = $self->prepare(
        "select transcript_id, transcript_name, translation_name, gene_name,
                chr_start, chr_end, chr_strand, external_name, external_db,
                exon_structure, type, coding_start, coding_end
           from $_db_name.www_transcript
          where chr_name = ? and chr_start <= ? and chr_start >= ? and
                chr_end >= ? and db = ?"
    );
    
    eval {
        $sth->execute( "$chr", $vc_end, $vc_start-3000000, $vc_start, $database );
    };
    return [] if($@);
    my @transcripts;
    while( my $row = $sth->fetchrow_arrayref() ) {
        push @transcripts, {
            'transcript'=> $row->[0],
            'stable_id' => $row->[1],
            'translation'=> $row->[2],
            'gene'      => $row->[3],
            'chr_start' => $row->[4],
            'chr_end'   => $row->[5],
            'start'     => $row->[4]-$vc_start+1,
            'end'       => $row->[5]-$vc_start+1,
            'coding_start' => $row->[11]-$vc_start+1,
            'coding_end'   => $row->[12]-$vc_start+1,
            'strand'    => $row->[6],
            'synonym'   => $row->[7],
            'db'        => $row->[8],
            'exon_structure' => [ split ':', $row->[9] ],
            'type'      => $row->[10]
        };
    }
    return $self->{$cache_name} = \@transcripts;
    return \@transcripts
}

sub fetch_virtualgenscans_start_end {
    my ( $self, $chr, $vc_start, $vc_end ) =@_;
    my $_db_name = $self->{'_lite_db_name'};
    my $cache_name = "_virtualgenscans_cache_$chr"."_$vc_start"."_$vc_end";
    
    return $self->{$cache_name} if( $self->{$cache_name} );
    my $sth = $self->prepare(
        "select id, chr_name, chr_start, chr_end, chr_strand, exon_structure
           from $_db_name.www_genscan
          where chr_name = ? and chr_start <= ? and chr_start >= ? and
                chr_end >= ?"
    );
    eval {
        $sth->execute( "$chr", $vc_end, $vc_start-1000000, $vc_start );
    };
    return [] if($@);
    my @transcripts;
    while( my $row = $sth->fetchrow_arrayref() ) {
        push @transcripts, {
            'genscan'   => $row->[0],
            'chr_start' => $row->[2],
            'chr_end'   => $row->[3],
            'start'     => $row->[2]-$vc_start+1,
            'end'       => $row->[3]-$vc_start+1,
            'strand'    => $row->[4],
            'exon_structure' => [ split ':', $row->[5] ]
        };
    }
    return $self->{$cache_name} = \@transcripts;
    return \@transcripts
}

sub fetch_virtualgenes_start_end {
    my ( $self, $chr, $vc_start, $vc_end ) =@_;
    my $_db_name = $self->{'_lite_db_name'};
    my $cache_name = "_virtualgenes_cache_$chr"."_$vc_start"."_$vc_end";
    return $self->{$cache_name} if( $self->{$cache_name} );
    my $sth = $self->prepare(
        "select g.gene_id, g.gene_stable_id, 
                g.chr_name, g.gene_chrom_start, g.gene_chrom_end,
                g.chrom_strand, g.display_id, g.db_name
           from $_db_name.gene as g 
          where g.chr_name = ? and g.gene_chrom_start <= ? and g.gene_chrom_start >= ? and
                g.gene_chrom_end >= ?"
    );
    eval {
        $sth->execute( "$chr", $vc_end, $vc_start-2000000, $vc_start );
    };
    return [] if($@);
    my @genes;
    while( my $row = $sth->fetchrow_arrayref() ) {
        push @genes, {
            'gene'      => $row->[0],
            'stable_id' => $row->[1],
            'chr_name'  => $row->[2],
            'chr_start' => $row->[3],
            'chr_end'   => $row->[4],
            'start'     => $row->[3]-$vc_start+1,
            'end'       => $row->[4]-$vc_start+1,
            'strand'    => $row->[5],
            'synonym'   => $row->[6],
            'db'        => $row->[7]
        };
    }
    return $self->{$cache_name} = \@genes;
    return \@genes
}
                
sub fetch_EMBLgenes_start_end {
    my ( $self, $chr, $vc_start, $vc_end ) =@_;
    my $_db_name = $self->{'_lite_db_name'};
    my $cache_name = "_emblgenes_cache_$chr"."_$vc_start"."_$vc_end";
    return $self->{$cache_name} if( $self->{$cache_name} );
    my $sth = $self->prepare(
        "select gene_id, gene_stable_id, 
                chr_name, gene_chrom_start, gene_chrom_end,
                chrom_strand, display_id, db_name, type
           from $_db_name.www_embl_gene 
          where chr_name = ? and gene_chrom_start <= ? and gene_chrom_start >= ? and
                gene_chrom_end >= ?"
    );
    eval {
        $sth->execute( "$chr", $vc_end, $vc_start-2000000, $vc_start );
    };
    return [] if($@);
    my @genes;
    while( my $row = $sth->fetchrow_arrayref() ) {
        push @genes, {
            'gene'      => $row->[0],
            'stable_id' => $row->[1],
            'chr_name'  => $row->[2],
            'chr_start' => $row->[3],
            'chr_end'   => $row->[4],
            'start'     => $row->[3]-$vc_start+1,
            'end'       => $row->[4]-$vc_start+1,
            'strand'    => $row->[5],
            'synonym'   => $row->[6],
            'db'        => $row->[7],
            'type'      => $row->[8]
        };
    }
    return $self->{$cache_name} = \@genes;
    return \@genes
}

sub fetch_SangerGenes_start_end {
    my ( $self, $chr, $vc_start, $vc_end ) =@_;
    my $_db_name = $self->{'_lite_db_name'};
    my $cache_name = "_sangergenes_cache_$chr"."_$vc_start"."_$vc_end";
    return $self->{$cache_name} if( $self->{$cache_name} );
    my $sth = $self->prepare(
        "select gene_id, gene_stable_id,
                chr_name, gene_chrom_start, gene_chrom_end,
                chrom_strand, display_id, db_name, type
           from $_db_name.www_sanger_gene
          where chr_name = ? and gene_chrom_start <= ? and gene_chrom_start >= ? and
                gene_chrom_end >= ? "
    );
    eval {
        $sth->execute( "$chr" , $vc_end, $vc_start-2000000, $vc_start );
    };
    return [] if($@);
    my @genes;
    while( my $row = $sth->fetchrow_arrayref() ) {
        push @genes, {
            'gene'      => $row->[0],
            'stable_id' => $row->[1],
            'chr_name'  => $row->[2],
            'chr_start' => $row->[3],
            'chr_end'   => $row->[4],
            'start'     => $row->[3]-$vc_start+1,
            'end'       => $row->[4]-$vc_start+1,
            'strand'    => $row->[5],
            'synonym'   => $row->[6],
            'db'        => $row->[7],
            'type'      => $row->[8]
        };
    }
    return $self->{$cache_name} = \@genes;
    return \@genes
}

sub fetch_virtualRepeatFeatures_start_end {
    my ( $self, $chr, $vc_start, $vc_end, $type, $glob_bp ) =@_;
    my $cache_name = "_repeats_$type"."_cache_$chr"."_$vc_start"."_$vc_end";
    return $self->{$cache_name} if( $self->{$cache_name} );
	$glob_bp ||= 0;
    my $_db_name = $self->{'_lite_db_name'};

    my $sth = $self->prepare(
        "select r.id, r.hid,  r.chr_name, r.repeat_chrom_start, r.repeat_chrom_end, r.repeat_chrom_strand
           from $_db_name.www_repeat as r
          where r.chr_name = ? and r.repeat_chrom_start <= ? and r.repeat_chrom_start >= ? and r.repeat_chrom_end >= ?".
		  	( (defined $type && $type ne '') ? " and r.type = '$type'" : '' ).
          " order by r.repeat_chrom_start"            
    );

    eval {
        $sth->execute( "$chr", $vc_end, $vc_start-1000000, $vc_start);
    };
    return [] if($@);

	my @repeats;
	my $old_start = -99999999999999999;
	my $old_end   = -99999999999999999;
	while( my $row = $sth->fetchrow_arrayref() ) {
      	my $end = $row->[4];
## Glob results! 
        next if($end < $old_end );
    	$old_end   = $end;
    	if( $end-$old_start < $glob_bp/2 ) {
			$repeats[-1]->{'end'} = $end - $vc_start + 1; 
	  	}	else {
    	  	$old_start = $row->[3];
			push @repeats, {
				'id'        => $row->[0],
				'hid'       => $row->[1],
    	        'chr_name'  => $row->[2],
        	    'chr_start' => $old_start,
            	'chr_end'   => $end,
        	    'start'     => $old_start-$vc_start+1,
            	'end'       => $end      -$vc_start+1,
	            'strand'    => $row->[5],
			};
		}
    }
    return $self->{$cache_name} = \@repeats;
    return \@repeats;
}


sub fetch_snp_features {

 my ( $self, $chr, $vc_start, $vc_end,$glob ) =@_;


 #lists of variations to be returned
    my @variations;
    my %hash;
    my $string; 

    my $_db_name = $self->{'_lite_db_name'};
   
    my $query = qq{

        SELECT   snp_chrom_start,strand,chrom_strand,
                 refsnpid,
                 tscid, hgbaseid,clone 
        FROM   	 $_db_name.snp
        WHERE  	 chr_name='$chr' 
        AND      snp_chrom_start>$vc_start
	AND      snp_chrom_start<$vc_end
              };

    #&eprof_start('snp-sql-query');

    my $sth = $self->prepare($query);

    eval {
        $sth->execute( );
    };
    return () if($@);
    #&eprof_end('snp-sql-query');

    my $snp;
    my $cl;

    #&eprof_start('snp-sql-object');

  SNP:
    while( (my $arr = $sth->fetchrow_arrayref()) ) {
        
        my ($snp_start, $strand,$chrom_strand,$snpuid,$tscid, $hgbaseid,$acc) = @{$arr};
            
  # globbing
        
        my $key=$snpuid.$acc;           # for purpose of filtering duplicates
        my %seen;                       # likewise
        
        
        if ( ! $seen{$key} )  {
            ## we're grabbing all the necessary stuff from the db in one
            ## SQL statement for speed purposes, so we have to do some
            ## duplicate filtering here.

            $seen{$key}++;
            
            #Variation
            $snp = new Bio::EnsEMBL::ExternalData::Variation
              (-start => $snp_start-$vc_start +1 ,
               -end => $snp_start-$vc_start +1,
               -strand => $chrom_strand,
               -original_strand => $strand,
               -score => 1,
               -source_tag => 'dbSNP',
              );
            
            my $link = new Bio::Annotation::DBLink;
            $link->database('dbSNP');
            $link->primary_id($snpuid);
           $link->optional_id($acc);
            #add dbXref to Variation
            $snp->add_DBLink($link);
	    if ($hgbaseid) {
	      my $link2 = new Bio::Annotation::DBLink;
	      $link2->database('HGBASE');
	      $link2->primary_id($hgbaseid);
	      $link2->optional_id($acc);
	      $snp->add_DBLink($link2);
	    }
	    if ($tscid) {
	      my $link3 = new Bio::Annotation::DBLink;
	      $link3->database('TSC-CSHL');
	      $link3->primary_id($tscid);
	      $link3->optional_id($acc);
	      #add dbXref to Variation
	      $snp->add_DBLink($link3);
	    }
            $cl=$acc;
            # set for compatibility to Virtual Contigs
            $snp->seqname($acc);
            #add SNP to the list
            push(@variations, $snp);
        }                               # if ! $seen{$key}
      }                                    # while a row from select statement

    #&eprof_end('snp-sql-object');
    
    return @variations;

}

sub fetch_virtualfeatures {
    my ( $self, $chr, $vc_start, $vc_end, $type, $score, $glob ) =@_;
    my $_db_name = $self->{'_lite_db_name'};
    my $cache_name = "_$type"."_cache_$chr"."_$vc_start"."_$vc_end"."_$score";
    return $self->{$cache_name} if( $self->{$cache_name} );
    my $sth = $self->prepare(
        "select id, score, chr_name, chr_start, chr_end, chr_strand
           from $_db_name.www_$type
          where chr_name=? and chr_start<=? and chr_start >= ? and chr_end >= ? and
                score >= ?"
    );
    eval {
        $sth->execute( "$chr", $vc_end, $vc_start-1000000, $vc_start, $score );
    };
    return [] if($@);
    my @features;
    while( my $row = $sth->fetchrow_arrayref() ) {
        push @features, {
            'chr_name'  => $row->[2],
            'chr_start' => $row->[3],
            'chr_end'   => $row->[4],
            'start'     => $row->[3] - $vc_start + 1,
            'end'       => $row->[4] - $vc_start + 1,
            'strand'    => $row->[5],
            'id'        => $row->[0],
            'score'     => $row->[1]
        };
    }
    return $self->{$cache_name} = \@features;
}
    
sub fetch_virtualsnps {
    my ( $self, $chr, $vc_start, $vc_end, $glob_bp ) =@_;
    $glob_bp||=0;
    my $_db_name = $self->{'_lite_db_name'};
    my $cache_name = "_snp_cache_$chr"."_$vc_start"."_$vc_end";
    return $self->{$cache_name} if( $self->{$cache_name} );
    my $sth = $self->prepare(
        "select  snp_chrom_start, strand,chrom_strand,
                 refsnpid, tscid, hgbaseid, clone 
        FROM   	 $_db_name.snp
        WHERE  	 chr_name=?
        AND      snp_chrom_start>=?
	    AND      snp_chrom_start<=?
        order by snp_chrom_start"
    );
    eval {
        $sth->execute( "$chr", $vc_start, $vc_end );
    };
    return [] if($@);
    my @variations;
	my $old_start = -99999999999999999;
	while( my $row = $sth->fetchrow_arrayref() ) {
      	my $start = $row->[0];
## Glob results! 
        next if($start < $old_start );
    	if($start < $old_start + $glob_bp/2) {
			$variations[-1]->{'end'} = $start - $vc_start+1;
	  	}	else {
            push @variations, {
                'chr_name'  => $chr,
                'chr_start' => $start,
                'chr_end'   => $start,
                'start'     => $start - $vc_start + 1,
                'end'       => $start - $vc_start + 1,
                'strand'    => $row->[2],
                'id'        => $row->[3],
                'tscid'     => $row->[4],
                'hgbaseid'  => $row->[5],
                'clone'     => $row->[6],
            };
    	  	$old_start = $start;
		}
    }

    return $self->{$cache_name} = \@variations;
}

1;
__END__

