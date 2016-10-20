package IP::Ban;

use strict;
use warnings;

use Carp qw(cluck);
use English qw( -no_match_vars );
use DBI;
use Gearman::Client;

# XXX
use Data::Dumper;

my $dsn = "DBI:mysql:database=ip_ban;host=sg-kvm;port=3306";
my $db_user = 'ip-ban-api';
my $db_pass = 'testerosa';


# TODO: Move to IP::Validate or IP::Helpers
# TODO: Add IPv6 support
sub validate_subnet {
	my $subnet = shift || confess('$subnet is required.');
	my $mask   = shift || confess('$mask is required.');

	my $error;

	my @octets = split(/\./x, $subnet);
	my $subnet_int = unpack('N', pack('CCCC', @octets));
	my $mask_int = (2**32) - (1 << (32 - $mask));

	if (($subnet_int & $mask_int) != $subnet_int) {
		$error = 'mask mismatch';
	}

	return $error;
}

##
# (Re)-process all pending tasks in the queue.
#
# TODO: Add options: force, task_id
sub run_queue {
	my $gmcli;
	my $dbh;
	my $sql;
	my $sth;
	my $gm_task_args;
	my $gm_task_id;
	my $gm_ret;

	$gmcli = Gearman::Client->new;
	$gmcli->job_servers('sg-kvm:4730');

	$dbh = DBI->connect($dsn, $db_user, $db_pass);
	$dbh->{RaiseError} = 1;

	$sql = 'SELECT q.id, q.ban_id, q.server_id, s.hostname, n.address, n.mask, TIME_FORMAT(TIMESTAMPDIFF(SECOND, q.created, NOW()), "%Hh%im%Ss") AS age';
	$sql .= ' FROM queue AS q';
	$sql .= ' INNER JOIN bans AS b ON (q.ban_id = b.id)';
	$sql .= ' INNER JOIN networks AS n ON (b.net_id = n.id)';
	$sql .= ' INNER JOIN servers AS s ON (q.server_id = s.id)';
	$sql .= " WHERE status != 'R' AND q.updated + INTERVAL q.retry second < NOW()";

	$sth = $dbh->prepare($sql);
	$sth->execute();

	while (my $row_ref = $sth->fetchrow_hashref()) {
		printf(STDERR "DEBUG: Retrying %s old task %s…\n", $row_ref->{'age'}, $row_ref->{'id'});

		$gm_task_args = sprintf("%s %s %s %s %s/%s\n", $row_ref->{'id'},
			$row_ref->{'ban_id'}, $row_ref->{'server_id'}, $row_ref->{'hostname'},
			$row_ref->{'address'}, $row_ref->{'mask'});

		$gm_task_id = sprintf("%s.%s.%s", $row_ref->{'id'},
			$row_ref->{'ban_id'}, $row_ref->{'server_id'});

		# We have our own double job protection mechanisms, but the earlier we
		# discard a duplicate job, the better, so use gearman "uniq" option.
		$gm_ret = $gmcli->dispatch_background("ban", $gm_task_args, {'uniq' => $gm_task_id});
		printf(STDERR "DEBUG: gm_ret = %s\n", $gm_ret);
	}

	$sth->finish();
	$dbh->disconnect();

	return;
}


##
# Add banned IP network to db and gearman.
#
# Ban is added to several tables and submitted to gearman in single
# transaction, so operation is either successful or not done at all.
#
# Bans can be appliued to individual servers or to groups of servers such as
# @all or @europe etc. The association Network<>Target is kept in the `bans`
# table.
#
# An IP network (including single IP address) could be banned on @all servers,
# or an arbitrary number of individual servers and @groups. IPs are kept in the
# `networks` table together with created/updated timestamps. If usage proves
# this to be unnecessary this information can be merged into `bans` table.
#
# @groups are then resolved to individual servers and added to the `queue`
# table together with task status, retry timers etc. This tables is later used
# and updated by the gearman workers.
#
# TODO: cron job to garbage collect bans with expired ttl
sub ban {
	my $subnet = shift || confess('$subnet is required');
	my $mask   = shift || confess('$mask is required');
	my $target = shift || '@all';
	my $ttl    = shift; # XXX: unused
	my $vs_err;

	printf(STDERR "DEBUG: subnet [%s] mask [%s] target [%s] ttl [%s]\n",
		$subnet, $mask, $target, $ttl);

	$vs_err = validate_subnet($subnet, $mask);
	if ($vs_err) {
		confess("Invalid subnet: $vs_err.");
	}

	my $dbh = DBI->connect($dsn, $db_user, $db_pass);

	$dbh->begin_work();
	$dbh->{RaiseError} = 1;

	my $evret = eval {
		my $group_id;
		my $net_id;
		my $ban_id;

		my $st1 = 'SELECT id FROM groups WHERE name=?';
		my $sth1 = $dbh->prepare($st1);
		$sth1->execute($target);
		my @g_row_ref = $sth1->fetchrow_array();
		$group_id = $g_row_ref[0];
		$sth1->finish();
	
		printf(STDERR "DEBUG: target's group_id = %s -> %s\n", $target, $group_id);
	
		if (!$group_id) {
			confess("Target [$target] not configured.");
		}
   
		# LAST_INSERT_ID(id): http://stackoverflow.com/a/779252/4308802 
		my $st2 = 'INSERT INTO networks SET address=?, mask=?, created=NOW()';
		$st2 .= ' ON DUPLICATE KEY UPDATE id=LAST_INSERT_ID(id), updated=NOW()';
		my $sth2 = $dbh->prepare($st2);
		$sth2->execute(@{[$subnet, $mask]});
		$sth2->finish();
   
		my $st3 = 'SELECT LAST_INSERT_ID()';
		my $sth3 = $dbh->prepare($st3);
		$sth3->execute();
		my @nra_row_ref = $sth3->fetchrow_array();
		$net_id = $nra_row_ref[0];
		$sth3->finish();
	
		my $st4 = 'INSERT INTO bans SET net_id=?, group_id=?, created=NOW(), expires=NOW()+INTERVAL ? second';
		$st4 .= ' ON DUPLICATE KEY UPDATE id=LAST_INSERT_ID(id), updated=NOW()';
		my $sth4 = $dbh->prepare($st4);
		my $rows_affected = $sth4->execute(@{[$net_id, $group_id, $ttl]});
		$sth4->finish();

		# Exit if ban was already here.
		if ($rows_affected == 2) {
			return "ban_exists";
		}

		my $st5 = 'SELECT LAST_INSERT_ID()';
		my $sth5 = $dbh->prepare($st5);
		$sth5->execute();
		my @bra_row_ref = $sth5->fetchrow_array();
		$ban_id = $bra_row_ref[0];
		$sth5->finish();

		# Resolve [target] group to individual servers
		my $st6  = 'SELECT s.id, s.hostname FROM servers AS s';
		$st6 .= ' INNER JOIN servers_groups AS sg ON (s.id = sg.server_id)';
		$st6 .= ' INNER JOIN groups AS g ON (sg.group_id = g.id)';
		$st6 .= ' WHERE g.id=?;';
		my $sth6 = $dbh->prepare($st6);
		$sth6->execute(@{[$group_id]});
		my @servers;
		while (my @server_row = $sth6->fetchrow_array()) {
			push(@servers, [$server_row[0], $server_row[1]]);
		}
		$sth6->finish();

		# Add to queue & gearman
		my $gmcli = Gearman::Client->new;
		$gmcli->job_servers('sg-kvm:4730');

		my $st7 = "INSERT INTO queue SET ban_id=?, server_id=?, task='ban', status='N', created=NOW()";
		my $st8 = 'SELECT LAST_INSERT_ID()';
		foreach my $server_row (@servers) {
			my $server_id   = $server_row->[0];
			my $server_name = $server_row->[1];

			my $sth7 = $dbh->prepare($st7);
			$sth7->execute(@{[$ban_id, $server_id]});
			$sth7->finish();

			my $sth8 = $dbh->prepare($st8);
			$sth8->execute();
			my @q_row_ref = $sth8->fetchrow_array();
			my $queue_id = $q_row_ref[0];
			$sth8->finish();

			printf(STDERR "DEBUG: queue_id [%s]\n", $queue_id);

			# We have our own double job protection mechanisms, but the earlier
			# we discard a duplicate job, the better, so use gearman "uniq"
			# option.
			my $gm_task_args = sprintf("%s %s %s %s %s/%s\n", $queue_id,
				$ban_id, $server_id, $server_name, $subnet, $mask);

			my $gm_task_id = sprintf("%s.%s.%s", $queue_id,
				$ban_id, $server_id);

			my $gm_ret = $gmcli->dispatch_background("ban", $gm_task_args, {'uniq' => $gm_task_id});
			printf(STDERR "DEBUG: gm_ret = %s\n", $gm_ret);
		}

		$dbh->commit();

		return;
	};

	if ($EVAL_ERROR || $evret) {
		if ($evret ne "ban_exists" || $EVAL_ERROR) {
			cluck("Transaction aborted because:\n\t($evret) [$EVAL_ERROR]\nRolling back.\n");
		}

		printf(STDERR "DEBUG: $evret\n");

		$dbh->rollback();
	}

	$dbh->disconnect();

	return;
}

sub unban {
	# * connect to mysql
	# * check if there's entry in ip_ban.bans or bail out
	# * check if there are jobs in the queue and bail out
	# * add task to gearman (unique)
	# * gearman worker will update ip_ban.queue (through API):
	#  - fn(queue.id, New → Work → Success = remove || Fail = retry)
	#  - last gearman worker will remove entry from ip_ban.bans if not referenced in queue

	croak('Not implemented yet');
}

sub get_bans {
	my $bans_ref = [];

	my $dbh = DBI->connect($dsn, $db_user, $db_pass);

	my $st = 'SELECT b.id, CONCAT(n.address, "/", n.mask) AS subnet, g.name AS target, b.expires, b.updated, b.created';
	$st .= ' FROM bans AS b';
	$st .= ' INNER JOIN networks AS n ON (b.net_id = n.id)';
	$st .= ' INNER JOIN groups AS g ON (b.group_id = g.id)';

	my $sth = $dbh->prepare($st)
		or confess("prepare statement failed: $dbh->errstr()");

	$sth->execute() or confess("execution failed: $dbh->errstr()");

	while (my $ref = $sth->fetchrow_hashref()) {
		push(@{$bans_ref}, $ref);
    }

    $sth->finish();
	$dbh->disconnect();

	return $bans_ref;
}

##
# Get list of tasks lurking in the queue.
#
# @param bool $status	only tasks marked as failed
# @return hashref
sub get_queue {
	my $status = shift;

	my $queue_ref = [];
	my $dbh;
	my $sql;
	my $sth;

	if ($status && $status ne "F") {
		confess("Internal error: unknown status [$status].");
	}

	$dbh = DBI->connect($dsn, $db_user, $db_pass);

	$sql  = 'SELECT q.id, CONCAT(n.address, "/", n.mask) AS subnet, s.hostname AS target, q.task, q.status, q.updated, q.created, q.retry';
	$sql .= ' FROM queue AS q';
	$sql .= ' INNER JOIN bans AS b ON (q.ban_id = b.id)';
	$sql .= ' INNER JOIN networks AS n ON (b.net_id = n.id)';
	$sql .= ' INNER JOIN servers AS s ON (q.server_id = s.id)';
	$sql .= " WHERE status='F'" if ($status && $status eq "F");

	$sth = $dbh->prepare($sql)
		or confess("prepare statement failed: $dbh->errstr()");

	$sth->execute() or confess("execution failed: $dbh->errstr()");

	while (my $ref = $sth->fetchrow_hashref()) {
		push(@{$queue_ref}, $ref);
	}

	$sth->finish();
	$dbh->disconnect();

	return $queue_ref;
}


1;
