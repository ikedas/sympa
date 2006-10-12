# Upgrade.pm - This module gathers all subroutines used to upgrade Sympa data structures
#<!-- RCS Identication ; $Revision$ --> 

#
# Sympa - SYsteme de Multi-Postage Automatique
# Copyright (c) 1997, 1998, 1999, 2000, 2001 Comite Reseau des Universites
# Copyright (c) 1997,1998, 1999 Institut Pasteur & Christophe Wolfhugel
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.

package Upgrade;

use strict;
require Exporter;
my @ISA = qw(Exporter);
my @EXPORT = qw();

use Carp;

use Conf;
use Log;

## Return the previous Sympa version, ie the one listed in data_structure.version
sub get_previous_version {
    my $version_file = "$Conf{'etc'}/data_structure.version";
    my $previous_version;
    
    if (-f $version_file) {
	unless (open VFILE, $version_file) {
	    do_log('err', "Unable to open %s : %s", $version_file, $!);
	    return undef;
	}
	while (<VFILE>) {
	    next if /^\s*$/;
	    next if /^\s*\#/;
	    chomp;
	    $previous_version = $_;
	    last;
	}
	close VFILE;

	return $previous_version;
    }
    
    return undef;
}

sub update_version {
    my $version_file = "$Conf{'etc'}/data_structure.version";

    ## Saving current version if required
    unless (open VFILE, ">$version_file") {
	do_log('err', "Unable to write %s ; sympa.pl needs write access on %s directory : %s", $version_file, $Conf{'etc'}, $!);
	return undef;
    }
    printf VFILE "# This file is automatically created by sympa.pl after installation\n# Unless you know what you are doing, you should not modify it\n";
    printf VFILE "%s\n", $Version::Version;
    close VFILE;
    
    return 1;
}


## Upgrade data structure from one version to another
sub upgrade {
    my ($previous_version, $new_version) = @_;

    &do_log('notice', 'Upgrade::upgrade(%s, %s)', $previous_version, $new_version);
    
    unless (&List::check_db_connect()) {
	return undef;
    }

    my $dbh = &List::db_get_handler();

    if (&tools::lower_version($new_version, $previous_version)) {
	&do_log('notice', 'Installing  older version of Sympa ; no upgrade operation is required');
	return 1;
    }

    ## Set 'subscribed' data field to '1' is none of 'subscribed' and 'included' is set
    if (&tools::lower_version($previous_version, '4.2a')) {

	my $statement = "UPDATE subscriber_table SET subscribed_subscriber=1 WHERE ((included_subscriber IS NULL OR included_subscriber!=1) AND (subscribed_subscriber IS NULL OR subscribed_subscriber!=1))";
	
	&do_log('notice','Updating subscribed field of the subscriber table...');
	my $rows = $dbh->do($statement);
	unless (defined $rows) {
	    &fatal_err("Unable to execute SQL statement %s : %s", $statement, $dbh->errstr);	    
	}
	&do_log('notice','%d rows have been updated', $rows);
    }    

    ## Migration to tt2
    if (&tools::lower_version($previous_version, '4.2b')) {

	&do_log('notice','Migrating templates to TT2 format...');	
	
	unless (open EXEC, '--SCRIPTDIR--/tpl2tt2.pl|') {
	    &do_log('err','Unable to run --SCRIPTDIR--/tpl2tt2.pl');
	    return undef;
	}
	close EXEC;
	
	&do_log('notice','Rebuilding web archives...');
	my $all_lists = &List::get_lists('*');
	foreach my $list ( @$all_lists ) {

	    next unless (defined $list->{'admin'}{'web_archive'});
	    my $file = $Conf{'queueoutgoing'}.'/.rebuild.'.$list->get_list_id();
	    
	    unless (open REBUILD, ">$file") {
		&do_log('err','Cannot create %s', $file);
		next;
	    }
	    print REBUILD ' ';
	    close REBUILD;
	}	
    }
    
    ## Initializing the new admin_table
    if (&tools::lower_version($previous_version, '4.2b.4')) {
	&do_log('notice','Initializing the new admin_table...');
	my $all_lists = &List::get_lists('*');
	foreach my $list ( @$all_lists ) {
	    $list->sync_include_admin();
	}
    }

    ## Move old-style web templates out of the include_path
    if (&tools::lower_version($previous_version, '5.0.1')) {
	&do_log('notice','Old web templates HTML structure is not compliant with latest ones.');
	&do_log('notice','Moving old-style web templates out of the include_path...');

	my @directories;

	if (-d "$Conf::Conf{'etc'}/web_tt2") {
	    push @directories, "$Conf::Conf{'etc'}/web_tt2";
	}

	## Go through Virtual Robots
	foreach my $vr (keys %{$Conf::Conf{'robots'}}) {

	    if (-d "$Conf::Conf{'etc'}/$vr/web_tt2") {
		push @directories, "$Conf::Conf{'etc'}/$vr/web_tt2";
	    }
	}

	## Search in V. Robot Lists
	my $all_lists = &List::get_lists('*');
	foreach my $list ( @$all_lists ) {
	    if (-d "$list->{'dir'}/web_tt2") {
		push @directories, "$list->{'dir'}/web_tt2";
	    }	    
	}

	my @templates;

	foreach my $d (@directories) {
	    unless (opendir DIR, $d) {
		printf STDERR "Error: Cannot read %s directory : %s", $d, $!;
		next;
	    }
	    
	    foreach my $tt2 (sort grep(/\.tt2$/,readdir DIR)) {
		push @templates, "$d/$tt2";
	    }
	    
	    closedir DIR;
	}

	foreach my $tpl (@templates) {
	    unless (rename $tpl, "$tpl.oldtemplate") {
		printf STDERR "Error : failed to rename $tpl to $tpl.oldtemplate : $!\n";
		next;
	    }

	    &do_log('notice','File %s renamed %s', $tpl, "$tpl.oldtemplate");
	}
    }


    ## Clean buggy list config files
    if (&tools::lower_version($previous_version, '5.1b')) {
	&do_log('notice','Cleaning buggy list config files...');
	my $all_lists = &List::get_lists('*');
	foreach my $list ( @$all_lists ) {
	    $list->save_config('listmaster@'.$list->{'domain'});
	}
    }

    ## Fix a bug in Sympa 5.1
    if (&tools::lower_version($previous_version, '5.1.2')) {
	&do_log('notice','Rename archives/log. files...');
	my $all_lists = &List::get_lists('*');
	foreach my $list ( @$all_lists ) {
	    my $l = $list->{'name'}; 
	    if (-f $list->{'dir'}.'/archives/log.') {
		rename $list->{'dir'}.'/archives/log.', $list->{'dir'}.'/archives/log.00';
	    }
	}
    }

    if (&tools::lower_version($previous_version, '5.2a.1')) {

	## Fill the robot_subscriber and robot_admin fields in DB
	&do_log('notice','Updating the new robot_subscriber and robot_admin  Db fields...');

	unless ($List::use_db) {
	    &do_log('info', 'Sympa not setup to use DBI');
	    return undef;
	}

	foreach my $r (keys %{$Conf{'robots'}}) {
	    my $all_lists = &List::get_lists($r, {'skip_sync_admin' => 1});
	    foreach my $list ( @$all_lists ) {
		
		foreach my $table ('subscriber','admin') {
		    my $statement = sprintf "UPDATE %s_table SET robot_%s=%s WHERE (list_%s=%s)",
		    $table,
		    $table,
		    $dbh->quote($r),
		    $table,
		    $dbh->quote($list->{'name'});

		    unless ($dbh->do($statement)) {
			do_log('err','Unable to execute SQL statement "%s" : %s', 
			       $statement, $dbh->errstr);
			&send_notify_to_listmaster('upgrade_failed', $Conf{'domain'},{'error' => $dbh->errstr});
			return undef;
		    }
		}
		
		## Force Sync_admin
		$list = new List ($list->{'name'}, $list->{'domain'}, {'force_sync_admin' => 1});
	    }
	}

	## Rename web archive directories using 'domain' instead of 'host'
	&do_log('notice','Renaming web archive directories with the list domain...');
	
	my $root_dir = &Conf::get_robot_conf($Conf{'host'},'arc_path');
	unless (opendir ARCDIR, $root_dir) {
	    do_log('err',"Unable to open $root_dir : $!");
	    return undef;
	}
	
	foreach my $dir (sort readdir(ARCDIR)) {
	    next if (($dir =~ /^\./o) || (! -d $root_dir.'/'.$dir)); ## Skip files and entries starting with '.'
		     
	    my ($listname, $listdomain) = split /\@/, $dir;

	    next unless ($listname && $listdomain);

	    my $list = new List $listname;
	    unless (defined $list) {
		do_log('notice',"Skipping unknown list $listname");
		next;
	    }
	    
	    if ($listdomain ne $list->{'domain'}) {
		my $old_path = $root_dir.'/'.$listname.'@'.$listdomain;		
		my $new_path = $root_dir.'/'.$listname.'@'.$list->{'domain'};

		if (-d $new_path) {
		    do_log('err',"Could not rename %s to %s ; directory already exists", $old_path, $new_path);
		    next;
		}else {
		    unless (rename $old_path, $new_path) {
			do_log('err',"Failed to rename %s to %s : %s", $old_path, $new_path, $!);
			next;
		    }
		    &do_log('notice', "Renamed %s to %s", $old_path, $new_path);
		}
	    }		     
	}
	close ARCDIR;
	
    }

    ## DB fields of enum type have been changed to int
    if (&tools::lower_version($previous_version, '5.2a.1')) {
	
	if ($List::use_db && $Conf{'db_type'} eq 'mysql') {
	    my %check = ('subscribed_subscriber' => 'subscriber_table',
			 'included_subscriber' => 'subscriber_table',
			 'subscribed_admin' => 'admin_table',
			 'included_admin' => 'admin_table');
	    
	    foreach my $field (keys %check) {

		my $statement;
				
		## Query the Database
		$statement = sprintf "SELECT max(%s) FROM %s", $field, $check{$field};
		
		my $sth;
		
		unless ($sth = $dbh->prepare($statement)) {
		    do_log('err','Unable to prepare SQL statement : %s', $dbh->errstr);
		    return undef;
		}
		
		unless ($sth->execute) {
		    do_log('err','Unable to execute SQL statement "%s" : %s', $statement, $dbh->errstr);
		    return undef;
		}
		
		my $max = $sth->fetchrow();
		$sth->finish();		

		## '0' has been mapped to 1 and '1' to 2
		## Restore correct field value
		if ($max > 1) {
		    ## 1 to 0
		    &do_log('notice', 'Fixing DB field %s ; turning 1 to 0...', $field);
		    
		    my $statement = sprintf "UPDATE %s SET %s=%d WHERE (%s=%d)", $check{$field}, $field, 0, $field, 1;
		    my $rows;
		    unless ($rows = $dbh->do($statement)) {
			do_log('err','Unable to execute SQL statement "%s" : %s', $statement, $dbh->errstr);
			return undef;
		    }
		    
		    &do_log('notice', 'Updated %d rows', $rows);

		    ## 2 to 1
		    &do_log('notice', 'Fixing DB field %s ; turning 2 to 1...', $field);
		    
		    my $statement = sprintf "UPDATE %s SET %s=%d WHERE (%s=%d)", $check{$field}, $field, 1, $field, 2;
		    my $rows;
		    unless ($rows = $dbh->do($statement)) {
			do_log('err','Unable to execute SQL statement "%s" : %s', $statement, $dbh->errstr);
			return undef;
		    }
		    
		    &do_log('notice', 'Updated %d rows', $rows);		    

		}
	    }
	}
    }

    ## Rename bounce sub-directories
    if (&tools::lower_version($previous_version, '5.2a.1')) {

	&do_log('notice','Renaming bounce sub-directories adding list domain...');
	
	my $root_dir = &Conf::get_robot_conf($Conf{'host'},'bounce_path');
	unless (opendir BOUNCEDIR, $root_dir) {
	    do_log('err',"Unable to open $root_dir : $!");
	    return undef;
	}
	
	foreach my $dir (sort readdir(BOUNCEDIR)) {
	    next if (($dir =~ /^\./o) || (! -d $root_dir.'/'.$dir)); ## Skip files and entries starting with '.'
		     
	    next if ($dir =~ /\@/); ## Directory already include the list domain

	    my $listname = $dir;
	    my $list = new List $listname;
	    unless (defined $list) {
		do_log('notice',"Skipping unknown list $listname");
		next;
	    }
	    
	    my $old_path = $root_dir.'/'.$listname;		
	    my $new_path = $root_dir.'/'.$listname.'@'.$list->{'domain'};
	    
	    if (-d $new_path) {
		do_log('err',"Could not rename %s to %s ; directory already exists", $old_path, $new_path);
		next;
	    }else {
		unless (rename $old_path, $new_path) {
		    do_log('err',"Failed to rename %s to %s : %s", $old_path, $new_path, $!);
		    next;
		}
		&do_log('notice', "Renamed %s to %s", $old_path, $new_path);
	    }
	}
	close BOUNCEDIR;
    }

    ## Update lists config using 'include_list'
    if (&tools::lower_version($previous_version, '5.2a.1')) {
	
	&do_log('notice','Update lists config using include_list parameter...');

	my $all_lists = &List::get_lists('*');
	foreach my $list ( @$all_lists ) {

	    if (defined $list->{'admin'}{'include_list'}) {
	    
		foreach my $index (0..$#{$list->{'admin'}{'include_list'}}) {
		    my $incl = $list->{'admin'}{'include_list'}[$index];
		    my $incl_list = new List ($incl);
		    
		    if (defined $incl_list &&
			$incl_list->{'domain'} ne $list->{'domain'}) {
			&do_log('notice','Update config file of list %s, including list %s', $list->get_list_id(), $incl_list->get_list_id());
			
			$list->{'admin'}{'include_list'}[$index] = $incl_list->get_list_id();

			$list->save_config('listmaster@'.$list->{'domain'});
		    }
		}
	    }
	}	
    }

    ## New mhonarc ressource file with utf-8 recoding
    if (&tools::lower_version($previous_version, '5.3a.6')) {
	
	&do_log('notice','Looking for customized mhonarc-ressources.tt2 files...');
	foreach my $vr (keys %{$Conf::Conf{'robots'}}) {
	    my $etc_dir = $Conf::Conf{'etc'};

	    if ($vr ne $Conf::Conf{'host'}) {
		$etc_dir .= '/'.$vr;
	    }

	    if (-f $etc_dir.'/mhonarc-ressources.tt2') {
		my $new_filename = $etc_dir.'/mhonarc-ressources.tt2'.'.'.time;
		rename $etc_dir.'/mhonarc-ressources.tt2', $new_filename;
		&do_log('notice', "Custom %s file has been backed up as %s", $etc_dir.'/mhonarc-ressources.tt2', $new_filename);
		&List::send_notify_to_listmaster('file_removed',$Conf::Conf{'host'},
						 [$etc_dir.'/mhonarc-ressources.tt2', $new_filename]);
	    }
	}


	&do_log('notice','Rebuilding web archives...');
	my $all_lists = &List::get_lists('*');
	foreach my $list ( @$all_lists ) {

	    next unless (defined $list->{'admin'}{'web_archive'});
	    my $file = $Conf{'queueoutgoing'}.'/.rebuild.'.$list->get_list_id();
	    
	    unless (open REBUILD, ">$file") {
		&do_log('err','Cannot create %s', $file);
		next;
	    }
	    print REBUILD ' ';
	    close REBUILD;
	}	

    }

    ## Changed shared documents name encoding
    ## They are Q-encoded therefore easier to store on any filesystem with any encoding
    if (&tools::lower_version($previous_version, '5.3a.8')) {
	&do_log('notice','Q-Encoding web documents filenames...');

	my $all_lists = &List::get_lists('*');
	foreach my $list ( @$all_lists ) {
	    if (-d $list->{'dir'}.'/shared') {
		&do_log('notice','  Processing list %s...', $list->get_list_address());

		## Determine default lang for this list
		## It should tell us what character encoding was used for filenames
		&Language::SetLang($list->{'admin'}{'lang'});
		my $list_encoding = &Language::GetCharset();

		my $count = &tools::qencode_hierarchy($list->{'dir'}.'/shared', $list_encoding);

		if ($count) {
		    &do_log('notice', 'List %s : %d filenames has been changed', $list->{'name'}, $count);
		}
	    }
	}

    }    

    return 1;
}

sub probe_db {
    &do_log('debug3', 'List::probe_db()');    
    my (%checked, $table);

    ## Database structure
    my %db_struct = ('mysql' => {'user_table' => {'email_user' => 'varchar(100)',
						  'gecos_user' => 'varchar(150)',
						  'password_user' => 'varchar(40)',
						  'cookie_delay_user' => 'int(11)',
						  'lang_user' => 'varchar(10)',
						  'attributes_user' => 'text'},
				 'subscriber_table' => {'list_subscriber' => 'varchar(50)',
							'user_subscriber' => 'varchar(100)',
							'robot_subscriber' => 'varchar(80)',
							'date_subscriber' => 'datetime',
							'update_subscriber' => 'datetime',
							'visibility_subscriber' => 'varchar(20)',
							'reception_subscriber' => 'varchar(20)',
							'topics_subscriber' => 'varchar(200)',
							'bounce_subscriber' => 'varchar(35)',
							'comment_subscriber' => 'varchar(150)',
							'subscribed_subscriber' => "int(1)",
							'included_subscriber' => "int(1)",
							'include_sources_subscriber' => 'varchar(50)',
							'bounce_score_subscriber' => 'smallint(6)',
							'bounce_address_subscriber' => 'varchar(100)'},
				 'admin_table' => {'list_admin' => 'varchar(50)',
						   'user_admin' => 'varchar(100)',
						   'robot_admin' => 'varchar(80)',
						   'role_admin' => "enum('listmaster','owner','editor')",
						   'date_admin' => 'datetime',
						   'update_admin' => 'datetime',
						   'reception_admin' => 'varchar(20)',
						   'comment_admin' => 'varchar(150)',
						   'subscribed_admin' => "int(1)",
						   'included_admin' => "int(1)",
						   'include_sources_admin' => 'varchar(50)',
						   'info_admin' =>  'varchar(150)',
						   'profile_admin' => "enum('privileged','normal')"},
				 'netidmap_table' => {'netid_netidmap' => 'varchar(100)',
						      'serviceid_netidmap' => 'varchar(100)',
						      'email_netidmap' => 'varchar(100)',
						      'robot_netidmap' => 'varchar(80)'},
				 'logs_table' => {'id_logs' => 'bigint(20)',
						  'date_logs' => 'int(11)',
						  'robot_logs' => 'varchar(80)',
						  'list_logs' => 'varchar(50)',
						  'action_logs' => 'varchar(50)',
						  'parameters_logs' => 'varchar(100)',
						  'target_email_logs' => 'varchar(100)',
						  'user_email_logs' => 'varchar(100)',
						  'msg_id_logs' => 'varchar(255)',
						  'status_logs' => 'varchar(10)',
						  'error_type_logs' => 'varchar(150)',
						  'client_logs' => 'varchar(100)',
						  'daemon_logs' => 'varchar(10)'						  
						  },				 
			     },
		     'SQLite' => {'user_table' => {'email_user' => 'varchar(100)',
						   'gecos_user' => 'varchar(150)',
						   'password_user' => 'varchar(40)',
						   'cookie_delay_user' => 'integer',
						   'lang_user' => 'varchar(10)',
						   'attributes_user' => 'varchar(255)'},
				  'subscriber_table' => {'list_subscriber' => 'varchar(50)',
							 'user_subscriber' => 'varchar(100)',
							 'robot_subscriber' => 'varchar(80)',
							 'date_subscriber' => 'timestamp',
							 'update_subscriber' => 'timestamp',
							 'visibility_subscriber' => 'varchar(20)',
							 'reception_subscriber' => 'varchar(20)',
							 'topics_subscriber' => 'varchar(200)',
							 'bounce_subscriber' => 'varchar(35)',
							 'comment_subscriber' => 'varchar(150)',
							 'subscribed_subscriber' => "boolean",
							 'included_subscriber' => "boolean",
							 'include_sources_subscriber' => 'varchar(50)',
							 'bounce_score_subscriber' => 'integer',
							 'bounce_address_subscriber' => 'varchar(100)'},
				  'admin_table' => {'list_admin' => 'varchar(50)',
						    'user_admin' => 'varchar(100)',
						    'robot_admin' => 'varchar(80)',
						    'role_admin' => "varchar(15)",
						    'date_admin' => 'timestamp',
						    'update_admin' => 'timestamp',
						    'reception_admin' => 'varchar(20)',
						    'comment_admin' => 'varchar(150)',
						    'subscribed_admin' => "boolean",
						    'included_admin' => "boolean",
						    'include_sources_admin' => 'varchar(50)',
						    'info_admin' =>  'varchar(150)',
						    'profile_admin' => "varchar(15)"},
				  'netidmap_table' => {'netid_netidmap' => 'varchar(100)',
						       'serviceid_netidmap' => 'varchar(100)',
						       'email_netidmap' => 'varchar(100)',
						       'robot_netidmap' => 'varchar(80)'},
				  'logs_table' => {'id_logs' => 'integer',
						   'date_logs' => 'integer',
						   'robot_logs' => 'varchar(80)',
						   'list_logs' => 'varchar(50)',
						   'action_logs' => 'varchar(50)',
						   'parameters_logs' => 'varchar(100)',
						   'target_email_logs' => 'varchar(100)',
						   'user_email_logs' => 'varchar(100)',
						   'msg_id_logs' => 'varchar(255)',
						   'status_logs' => 'varchar(10)',
						   'error_type_logs' => 'varchar(150)',
						   'client_logs' => 'varchar(100)',
						   'daemon_logs' => 'varchar(10)'						  
						  },				 

			      },
		     );
    
    my %not_null = ('email_user' => 1,
		    'list_subscriber' => 1,
		    'robot_subscriber' => 1,
		    'user_subscriber' => 1,
		    'date_subscriber' => 1,
		    'list_admin' => 1,
		    'robot_admin' => 1,
		    'user_admin' => 1,
		    'role_admin' => 1,
		    'date_admin' => 1,
		    'netid_netidmap' => 1,
		    'serviceid_netidmap' => 1,
		    'robot_netidmap' => 1,
		    'id_logs' => 1,
		    'date_logs' => 1,
		    'action_logs' => 1,
		    'status_logs' => 1,
		    'daemon_logs' => 1
		    );
    
    my %primary = ('user_table' => ['email_user'],
		   'subscriber_table' => ['list_subscriber','robot_subscriber','user_subscriber'],
		   'admin_table' => ['list_admin','robot_admin','user_admin','role_admin'],
		   'netidmap_table' => ['netid_netidmap','serviceid_netidmap','robot_netidmap'],
		   'logs_table' => ['id_logs']
		   );
    
    ## Report changes to listmaster
    my @report;

    ## Is the Database defined
    unless ($Conf{'db_name'}) {
	&do_log('err', 'No db_name defined in configuration file');
	return undef;
    }

    unless (&List::check_db_connect()) {
	unless (&SQLSource::create_db()) {
	    return undef;
	}

	if ($ENV{'HTTP_HOST'}) { ## Web context
	    return undef unless &List::db_connect('just_try');
	}else {
	    return undef unless &List::db_connect();
	}
    }
    
    my $dbh = &List::db_get_handler();

    my (@tables, $fields, %real_struct);
    if ($Conf{'db_type'} eq 'mysql') {
	
	## Get tables
	@tables = $dbh->tables();
	
	## Clean table names that could be surrounded by `` (recent DBD::mysql release)
	foreach my $t (@tables) {
	    $t =~ s/^\`(.+)\`$/\1/;
	}
	
	unless (defined $#tables) {
	    &do_log('info', 'Can\'t load tables list from database %s : %s', $Conf{'db_name'}, $dbh->errstr);
	    return undef;
	}
	
	## Check required tables
	foreach my $t1 (keys %{$db_struct{'mysql'}}) {
	    my $found;
	    foreach my $t2 (@tables) {
		$found = 1 if ($t1 eq $t2);
	    }
	    unless ($found) {
		unless ($dbh->do("CREATE TABLE $t1 (temporary INT)")) {
		    &do_log('err', 'Could not create table %s in database %s : %s', $t1, $Conf{'db_name'}, $dbh->errstr);
		    next;
		}
		
		push @report, sprintf('Table %s created in database %s', $t1, $Conf{'db_name'});
		&do_log('notice', 'Table %s created in database %s', $t1, $Conf{'db_name'});
		push @tables, $t1;
		$real_struct{$t1} = {};
	    }
	}

	## Get fields
	foreach my $t (@tables) {
	    my $sth;

	    #	    unless ($sth = $dbh->table_info) {
	    #	    unless ($sth = $dbh->prepare("LISTFIELDS $t")) {
	    unless ($sth = $dbh->prepare("SHOW FIELDS FROM $t")) {
		do_log('err','Unable to prepare SQL query : %s', $dbh->errstr);
		return undef;
	    }
	    
	    unless ($sth->execute) {
		do_log('err','Unable to execute SQL query : %s', $dbh->errstr);
		return undef;
	    }
	    
	    while (my $ref = $sth->fetchrow_hashref()) {
		$real_struct{$t}{$ref->{'Field'}} = $ref->{'Type'};
	    }

	    $sth->finish();
	}
	
    }elsif ($Conf{'db_type'} eq 'Pg') {
		
	unless (@tables = $dbh->tables) {
	    &do_log('err', 'Can\'t load tables list from database %s', $Conf{'db_name'});
	    return undef;
	}
    }elsif ($Conf{'db_type'} eq 'SQLite') {
 	
 	unless (@tables = $dbh->tables) {
 	    &do_log('err', 'Can\'t load tables list from database %s', $Conf{'db_name'});
 	    return undef;
 	}
	
 	foreach my $t (@tables) {
 	    $t =~ s/^\"(.+)\"$/\1/;
 	}
	
	foreach my $t (@tables) {
	    next unless (defined $db_struct{$Conf{'db_type'}}{$t});

	    my $res = $dbh->selectall_arrayref("PRAGMA table_info($t)");
	    unless (defined $res) {
		&do_log('err','Failed to check DB tables structure : %s', $dbh->errstr);
		next;
	    }
	    foreach my $field (@$res) {
		$real_struct{$t}{$field->[1]} = $field->[2];
	    }
	}

	# Une simple requ�te sqlite : PRAGMA table_info('nomtable') , retourne la liste des champs de la table en question.
	# La liste retourn�e est compos�e d'un N�Ordre, Nom du champ, Type (longueur), Null ou not null (99 ou 0),Valeur par d�faut,Cl� primaire (1 ou 0)
	
    }elsif ($Conf{'db_type'} eq 'Oracle') {
 	
 	my $statement = "SELECT table_name FROM user_tables";	 
	
	my $sth;
	
	unless ($sth = $dbh->prepare($statement)) {
	    do_log('err','Unable to prepare SQL query : %s', $dbh->errstr);
	    return undef;
     	}
	
       	unless ($sth->execute) {
	    &do_log('err','Can\'t load tables list from database and Unable to perform SQL query %s : %s ',$statement, $dbh->errstr);
	    return undef;
     	}
	
	## Process the SQL results
     	while (my $table= $sth->fetchrow()) {
	    push @tables, lc ($table);   	
	}
	
     	$sth->finish();
	
    }elsif ($Conf{'db_type'} eq 'Sybase') {
	
	my $statement = sprintf "SELECT name FROM %s..sysobjects WHERE type='U'",$Conf{'db_name'};
#	my $statement = "SELECT name FROM sympa..sysobjects WHERE type='U'";     
	
	my $sth;
	unless ($sth = $dbh->prepare($statement)) {
	    do_log('err','Unable to prepare SQL query : %s', $dbh->errstr);
	    return undef;
	}
	unless ($sth->execute) {
	    &do_log('err','Can\'t load tables list from database and Unable to perform SQL query %s : %s ',$statement, $dbh->errstr);
	    return undef;
	}
	
	## Process the SQL results
	while (my $table= $sth->fetchrow()) {
	    push @tables, lc ($table);   
	}
	
	$sth->finish();
    }

    foreach $table ( @tables ) {
	$checked{$table} = 1;
    }
    
    my $found_tables = 0;
    foreach $table('user_table', 'subscriber_table', 'admin_table') {
	if ($checked{$table} || $checked{'public.' . $table}) {
	    $found_tables++;
	}else {
	    &do_log('err', 'Table %s not found in database %s', $table, $Conf{'db_name'});
	}
    }
    
    ## Check tables structure if we could get it
    ## Currently only performed with mysql
    if (%real_struct) {
	foreach my $t (keys %{$db_struct{$Conf{'db_type'}}}) {
	    unless ($real_struct{$t}) {
		&do_log('err', 'Table \'%s\' not found in database \'%s\' ; you should create it with create_db.%s script', $t, $Conf{'db_name'}, $Conf{'db_type'});
		return undef;
	    }
	    
	    my %added_fields;
	    
	    foreach my $f (sort keys %{$db_struct{$Conf{'db_type'}}{$t}}) {
		unless ($real_struct{$t}{$f}) {
		    push @report, sprintf('Field \'%s\' (table \'%s\' ; database \'%s\') was NOT found. Attempting to add it...', $f, $t, $Conf{'db_name'});
		    &do_log('info', 'Field \'%s\' (table \'%s\' ; database \'%s\') was NOT found. Attempting to add it...', $f, $t, $Conf{'db_name'});
		    
		    my $options;
		    ## To prevent "Cannot add a NOT NULL column with default value NULL" errors
		    if ($not_null{$f}) {
			$options .= 'NOT NULL';
		    }

		    unless ($dbh->do("ALTER TABLE $t ADD $f $db_struct{$Conf{'db_type'}}{$t}{$f} $options")) {
			&do_log('err', 'Could not add field \'%s\' to table\'%s\'.', $f, $t);
			&do_log('err', 'Sympa\'s database structure may have change since last update ; please check RELEASE_NOTES');
			return undef;
		    }
		    
		    push @report, sprintf('Field %s added to table %s', $f, $t);
		    &do_log('info', 'Field %s added to table %s', $f, $t);
		    $added_fields{$f} = 1;

		    ## Remove temporary DB field
		    if ($real_struct{$t}{'temporary'}) {
			unless ($dbh->do("ALTER TABLE $t DROP temporary")) {
			    &do_log('err', 'Could not drop temporary table field : %s', $dbh->errstr);
			}
			delete $real_struct{$t}{'temporary'};
		    }
		    
		    next;
		}
		
		
		## Change DB types if different and if update_db_types enabled
		if ($Conf{'update_db_field_types'} eq 'auto') {
		    unless ($real_struct{$t}{$f} eq $db_struct{$Conf{'db_type'}}{$t}{$f}) {
			push @report, sprintf('Field \'%s\'  (table \'%s\' ; database \'%s\') does NOT have awaited type (%s). Attempting to change it...', 
					      $f, $t, $Conf{'db_name'}, $db_struct{$Conf{'db_type'}}{$t}{$f});
			&do_log('notice', 'Field \'%s\'  (table \'%s\' ; database \'%s\') does NOT have awaited type (%s). Attempting to change it...', 
				$f, $t, $Conf{'db_name'}, $db_struct{$Conf{'db_type'}}{$t}{$f});
			
			my $options;
			if ($not_null{$f}) {
			    $options .= 'NOT NULL';
			}

			push @report, sprintf("ALTER TABLE $t CHANGE $f $f $db_struct{$Conf{'db_type'}}{$t}{$f} $options");
			&do_log('notice', "ALTER TABLE $t CHANGE $f $f $db_struct{$Conf{'db_type'}}{$t}{$f} $options");
			unless ($dbh->do("ALTER TABLE $t CHANGE $f $f $db_struct{$Conf{'db_type'}}{$t}{$f} $options")) {
			    &do_log('err', 'Could not change field \'%s\' in table\'%s\'.', $f, $t);
			    &do_log('err', 'Sympa\'s database structure may have change since last update ; please check RELEASE_NOTES');
			    return undef;
			}
			
			push @report, sprintf('Field %s in table %s, structur updated', $f, $t);
			&do_log('info', 'Field %s in table %s, structur updated', $f, $t);
		    }
		}else {
		    unless ($real_struct{$t}{$f} eq $db_struct{$Conf{'db_type'}}{$t}{$f}) {
			&do_log('err', 'Field \'%s\'  (table \'%s\' ; database \'%s\') does NOT have awaited type (%s).', $f, $t, $Conf{'db_name'}, $db_struct{$Conf{'db_type'}}{$t}{$f});
			&do_log('err', 'Sympa\'s database structure may have change since last update ; please check RELEASE_NOTES');
			return undef;
		    }
		}
	    }

	    ## Create required INDEX and PRIMARY KEY
	    my $should_update;
	    foreach my $field (@{$primary{$t}}) {		
		if ($added_fields{$field}) {
		    $should_update = 1;
		    last;
		}
	    }
	    
	    if ($should_update) {
		my $fields = join ',',@{$primary{$t}};

		## drop previous primary key
		unless ($dbh->do("ALTER TABLE $t DROP PRIMARY KEY")) {
		    &do_log('err', 'Could not drop PRIMARY KEY, table\'%s\'.', $t);
		}
		push @report, sprintf('Table %s, PRIMARY KEY dropped', $t);
		&do_log('info', 'Table %s, PRIMARY KEY dropped', $t);

		## Add primary key
		&do_log('debug', "ALTER TABLE $t ADD PRIMARY KEY ($fields)");
		unless ($dbh->do("ALTER TABLE $t ADD PRIMARY KEY ($fields)")) {
		    &do_log('err', 'Could not set field \'%s\' as PRIMARY KEY, table\'%s\'.', $fields, $t);
		    return undef;
		}
		push @report, sprintf('Table %s, PRIMARY KEY set on %s', $t, $fields);
		&do_log('info', 'Table %s, PRIMARY KEY set on %s', $t, $fields);


		## drop previous index, but we don't know the index name
		my $success;
		foreach my $field (@{$primary{$t}}) {		
		    unless ($dbh->do("ALTER TABLE $t DROP INDEX $field")) {
			next;
		    }
		    $success = 1; last;
		}

		if ($success) {
		    push @report, sprintf('Table %s, INDEX dropped', $t);
		    &do_log('info', 'Table %s, INDEX dropped', $t);
		}else {
		    &do_log('err', 'Could not drop INDEX, table \'%s\'.', $t);
		}

		## Add INDEX
		unless ($dbh->do("ALTER TABLE $t ADD INDEX $t\_index ($fields)")) {
		    &do_log('err', 'Could not set INDEX on field \'%s\', table\'%s\'.', $fields, $t);
		    return undef;
		}
		push @report, sprintf('Table %s, INDEX set on %s', $t, $fields);
		&do_log('info', 'Table %s, INDEX set on %s', $t, $fields);

	    }
	    
	}

	## Try to run the create_db.XX script
    }elsif ($found_tables == 0) {
	unless (open SCRIPT, "--SCRIPTDIR--/create_db.$Conf{'db_type'}") {
	    &do_log('err', "Failed to open '%s' file : %s", "--SCRIPTDIR--/create_db.$Conf{'db_type'}", $!);
	    return undef;
	}
	my $script;
	while (<SCRIPT>) {
	    $script .= $_;
	}
	close SCRIPT;
	my @scripts = split /;\n/,$script;

	push @report, sprintf("Running the '%s' script...", "--SCRIPTDIR--/create_db.$Conf{'db_type'}");
	&do_log('notice', "Running the '%s' script...", "--SCRIPTDIR--/create_db.$Conf{'db_type'}");
	foreach my $sc (@scripts) {
	    next if ($sc =~ /^\#/);
	    unless ($dbh->do($sc)) {
		&do_log('err', "Failed to run script '%s' : %s", "--SCRIPTDIR--/create_db.$Conf{'db_type'}", $dbh->errstr);
		return undef;
	    }
	}

	## SQLite :  the only access permissions that can be applied are 
	##           the normal file access permissions of the underlying operating system
	if (($Conf{'db_type'} eq 'SQLite') &&  (-f $Conf{'db_name'})) {
	    `chown --USER-- $Conf{'db_name'}`; ## Failed with chmod() perl subroutine
	    `chgrp --GROUP-- $Conf{'db_name'}`; ## Failed with chmod() perl subroutine
	}

    }elsif ($found_tables < 3) {
	&do_log('err', 'Missing required tables in the database ; you should create them with create_db.%s script', $Conf{'db_type'});
	return undef;
    }
    
    ## Notify listmaster
    &List::send_notify_to_listmaster('db_struct_updated',  $Conf::Conf{'domain'}, {'report' => \@report}) if ($#report >= 0);

    return 1;
}

## Check if data structures are uptodate
## If not, no operation should be performed before the upgrade process is run
sub data_structure_uptodate {
     my $version_file = "$Conf{'etc'}/data_structure.version";
     my $data_structure_version;

     if (-f $version_file) {
	 unless (open VFILE, $version_file) {
	     do_log('err', "Unable to open %s : %s", $version_file, $!);
	     return undef;
	 }
	 while (<VFILE>) {
	     next if /^\s*$/;
	     next if /^\s*\#/;
	     chomp;
	     $data_structure_version = $_;
	     last;
	 }
	 close VFILE;
     }

     if (defined $data_structure_version &&
	 $data_structure_version ne $Version::Version) {
	 &do_log('err', "Data structure (%s) is not uptodate for current release (%s)", $data_structure_version, $Version::Version);
	 return 0;
     }

     return 1;
 }

## Packages must return true.
1;
