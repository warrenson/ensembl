CREATE TABLE `go_xref` (
  `object_xref_id` int(10) unsigned NOT NULL default '0',
  `linkage_type` enum('IC','IDA','IEA','IEP','IGI','IMP','IPI','ISS','NAS','ND','TAS','NR', 'RCA') collate latin1_bin NOT NULL default 'IC',
  UNIQUE KEY `object_xref_id_2` (`object_xref_id`,`linkage_type`),
  KEY `object_xref_id` (`object_xref_id`)
) ENGINE=MyISAM DEFAULT CHARSET=latin1 COLLATE=latin1_bin;

