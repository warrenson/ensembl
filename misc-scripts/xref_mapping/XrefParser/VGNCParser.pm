=head1 LICENSE

Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
Copyright [2016-2017] EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=cut

package XrefParser::VGNCParser;

use strict;
use warnings;
use File::Basename;
use Carp;
use base qw( XrefParser::BaseParser );

sub run {

  my ($self, $ref_arg) = @_;
  my $source_id    = $ref_arg->{source_id};
  my $species_id   = $ref_arg->{species_id};
  my $files        = $ref_arg->{files};
  my $verbose      = $ref_arg->{verbose};

  if((!defined $source_id) or (!defined $species_id) or (!defined $files) ){
    croak "Need to pass source_id, species_id, files and rel_file as pairs";
  }
  $verbose |=0;

  my $file = @{$files}[0];

  my $mismatch = 0;
  my $count = 0;

  my $hugo_io = $self->get_filehandle($file);

  if ( !defined $hugo_io ) {
    print "ERROR: Can't open VGNC file $file\n";
    return 1;
  }

  my $source_name = $self->get_source_name_for_source_id($source_id);

  # Skip header
  $hugo_io->getline();

  while ( $_ = $hugo_io->getline() ) {
    chomp;
    my @array = split /\t/x, $_;

    my $seen = 0;

    my $acc              = $array[0];
    my $symbol           = $array[1];
    my $name             = $array[2];


    #
    # Direct Ensembl mappings
    #
    my $id = $array[19];
    if ($id){              # Ensembl direct xref
      $seen = 1;
      $self->add_to_direct_xrefs({ stable_id  => $id,
				   type       => 'gene',
				   acc        => $acc,
				   label      => $symbol,
				   desc       => $name,,
				   source_id  => $source_id,
				   species_id => $species_id} );

      $count++;
    }


    if(!$seen){ # Store to keep descriptions etc
      $self->add_xref({ acc        => $acc,
			label      => $symbol,
			desc       => $name,
			source_id  => $source_id,
			species_id => $species_id,
			info_type  => "MISC"} );

      $mismatch++;
    }
  }


  $hugo_io->close();

  if($verbose){
    print "Loaded a total of $count xrefs\n";
    print "$mismatch xrefs could not be associated via ensembl\n";
  }
  return 0; # successful
}


1;


