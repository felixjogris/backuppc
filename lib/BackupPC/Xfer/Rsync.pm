#============================================================= -*-perl-*-
#
# BackupPC::Xfer::Rsync package
#
# DESCRIPTION
#
#   This library defines a BackupPC::Xfer::Rsync class for managing
#   the rsync-based transport of backup data from the client.
#
# AUTHOR
#   Craig Barratt  <cbarratt@users.sourceforge.net>
#
# COPYRIGHT
#   Copyright (C) 2002  Craig Barratt
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program; if not, write to the Free Software
#   Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
#
#========================================================================
#
# Version 2.0.0_CVS, released 3 Feb 2003.
#
# See http://backuppc.sourceforge.net.
#
#========================================================================

package BackupPC::Xfer::Rsync;

use strict;
use BackupPC::View;
use BackupPC::Xfer::RsyncFileIO;

use vars qw( $RsyncLibOK $RsyncLibErr );

BEGIN {
    eval "use File::RsyncP;";
    if ( $@ ) {
        #
        # Rsync module doesn't exist.
        #
        $RsyncLibOK = 0;
        $RsyncLibErr = "File::RsyncP module doesn't exist";
    } else {
        if ( $File::RsyncP::VERSION < 0.30 ) {
            $RsyncLibOK = 0;
            $RsyncLibErr = "File::RsyncP module version too old: need 0.30";
        } else {
            $RsyncLibOK = 1;
        }
    }
};

sub new
{
    my($class, $bpc, $args) = @_;

    return if ( !$RsyncLibOK );
    $args ||= {};
    my $t = bless {
        bpc       => $bpc,
        conf      => { $bpc->Conf },
        host      => "",
        hostIP    => "",
        shareName => "",
        badFiles  => [],

	#
	# Various stats
	#
        byteCnt         => 0,
	fileCnt         => 0,
	xferErrCnt      => 0,
	xferBadShareCnt => 0,
	xferBadFileCnt  => 0,
	xferOK          => 0,

	#
	# User's args
	#
        %$args,
    }, $class;

    return $t;
}

sub args
{
    my($t, $args) = @_;

    foreach my $arg ( keys(%$args) ) {
	$t->{$arg} = $args->{$arg};
    }
}

sub useTar
{
    return 0;
}

sub start
{
    my($t) = @_;
    my $bpc = $t->{bpc};
    my $conf = $t->{conf};
    my(@fileList, $rsyncClientCmd, $rsyncArgs, $logMsg,
       $incrDate, $argList, $fioArgs);

    #
    # We add a slash to the share name we pass to rsync
    #
    ($t->{shareNameSlash} = "$t->{shareName}/") =~ s{//+$}{/};

    if ( $t->{type} eq "restore" ) {
        $rsyncClientCmd = $conf->{RsyncClientRestoreCmd};
	$rsyncArgs = $conf->{RsyncRestoreArgs};
	my $remoteDir = "$t->{shareName}/$t->{pathHdrDest}";
	$remoteDir    =~ s{//+}{/}g;
        $argList = ['--server', @$rsyncArgs, '.', $remoteDir];
	$fioArgs = {
	    client   => $t->{bkupSrcHost},
	    share    => $t->{bkupSrcShare},
	    viewNum  => $t->{bkupSrcNum},
	    fileList => $t->{fileList},
	};
        $logMsg = "restore started below directory $t->{shareName}"
		. " to host $t->{host}";
    } else {
	#
	# Turn $conf->{BackupFilesOnly} and $conf->{BackupFilesExclude}
	# into a hash of arrays of files.
	#
	$conf->{RsyncShareName} = [ $conf->{RsyncShareName} ]
			unless ref($conf->{RsyncShareName}) eq "ARRAY";
	foreach my $param qw(BackupFilesOnly BackupFilesExclude) {
	    next if ( !defined($conf->{$param}) );
	    if ( ref($conf->{$param}) eq "ARRAY" ) {
		$conf->{$param} = {
			$conf->{RsyncShareName}[0] => $conf->{$param}
		};
	    } elsif ( ref($conf->{$param}) eq "HASH" ) {
		# do nothing
	    } else {
		$conf->{$param} = {
			$conf->{RsyncShareName}[0] => [ $conf->{$param} ]
		};
	    }
	}
        if ( defined($conf->{BackupFilesOnly}{$t->{shareName}}) ) {
            my(@inc, @exc, %incDone, %excDone);
            foreach my $file ( @{$conf->{BackupFilesOnly}{$t->{shareName}}} ) {
                #
                # If the user wants to just include /home/craig, then
                # we need to do create include/exclude pairs at
                # each level:
                #     --include /home --exclude /*
                #     --include /home/craig --exclude /home/*
                #
                # It's more complex if the user wants to include multiple
                # deep paths.  For example, if they want /home/craig and
                # /var/log, then we need this mouthfull:
                #     --include /home --include /var --exclude /*
                #     --include /home/craig --exclude /home/*
                #     --include /var/log --exclude /var/*
                #
                # To make this easier we do all the includes first and all
                # of the excludes at the end (hopefully they commute).
                #
                $file = "/$file";
                $file =~ s{//+}{/}g;
                my $f = "";
                while ( $file =~ m{^/([^/]*)(.*)} ) {
                    my $elt = $1;
                    $file = $2;
                    if ( $file eq "/" ) {
                        #
                        # preserve a tailing slash
                        #
                        $file = "";
                        $elt = "$elt/";
                    }
                    push(@exc, "$f/*") if ( !$excDone{"$f/*"} );
                    $excDone{"$f/*"} = 1;
                    $f = "$f/$elt";
                    push(@inc, $f) if ( !$incDone{$f} );
                    $incDone{$f} = 1;
                }
            }
            foreach my $file ( @inc ) {
                push(@fileList, "--include=$file");
            }
            foreach my $file ( @exc ) {
                push(@fileList, "--exclude=$file");
            }
        }
        if ( defined($conf->{BackupFilesExclude}{$t->{shareName}}) ) {
            foreach my $file ( @{$conf->{BackupFilesExclude}{$t->{shareName}}} )
            {
                #
                # just append additional exclude lists onto the end
                #
                push(@fileList, "--exclude=$file");
            }
        }
        if ( $t->{type} eq "full" ) {
            $logMsg = "full backup started for directory $t->{shareName}";
        } else {
            $incrDate = $bpc->timeStampISO($t->{lastFull} - 3600, 1);
            $logMsg = "incr backup started back to $incrDate for directory"
                    . " $t->{shareName}";
        }
        
        #
        # A full dump is implemented with --ignore-times: this causes all
        # files to be checksummed, even if the attributes are the same.
        # That way all the file contents are checked, but you get all
        # the efficiencies of rsync: only files deltas need to be
        # transferred, even though it is a full dump.
        #
	$rsyncArgs = $conf->{RsyncArgs};
	$rsyncArgs = [@$rsyncArgs, @fileList] if ( @fileList );
        $rsyncArgs = [@$rsyncArgs, "--ignore-times"]
                                    if ( $t->{type} eq "full" );
	$rsyncClientCmd = $conf->{RsyncClientCmd};
        $argList = ['--server', '--sender', @$rsyncArgs,
                              '.', $t->{shareNameSlash}];
	$fioArgs = {
	    client  => $t->{client},
	    share   => $t->{shareName},
	    viewNum => $t->{lastFullBkupNum},
	};
    }

    #
    # Merge variables into $rsyncClientCmd
    #
    my $args = {
	host      => $t->{host},
	hostIP    => $t->{hostIP},
	client    => $t->{client},
	shareName => $t->{shareName},
	shareNameSlash => $t->{shareNameSlash},
	rsyncPath => $conf->{RsyncClientPath},
	sshPath   => $conf->{SshPath},
	argList   => $argList,
    };
    $rsyncClientCmd = $bpc->cmdVarSubstitute($rsyncClientCmd, $args);

    #
    # Create the Rsync object, and tell it to use our own File::RsyncP::FileIO
    # module, which handles all the special BackupPC file storage
    # (compression, mangling, hardlinks, special files, attributes etc).
    #
    $t->{rsyncClientCmd} = $rsyncClientCmd;
    $t->{rs} = File::RsyncP->new({
	logLevel     => $conf->{RsyncLogLevel},
	rsyncCmd     => sub {
			    $bpc->cmdExecOrEval($rsyncClientCmd, $args);
			},
	rsyncCmdType => "full",
	rsyncArgs    => $rsyncArgs,
	timeout      => $conf->{ClientTimeout},
	logHandler   => sub {
			  my($str) = @_;
			  $str .= "\n";
			  $t->{XferLOG}->write(\$str);
		        },
	fio          => BackupPC::Xfer::RsyncFileIO->new({
			    xfer       => $t,
			    bpc        => $t->{bpc},
			    conf       => $t->{conf},
			    backups    => $t->{backups},
			    logLevel   => $conf->{RsyncLogLevel},
			    logHandler => sub {
					      my($str) = @_;
					      $str .= "\n";
					      $t->{XferLOG}->write(\$str);
					  },
			    %$fioArgs,
		      }),
    });

    delete($t->{_errStr});

    return $logMsg;
}

sub run
{
    my($t) = @_;
    my $rs = $t->{rs};
    my $conf = $t->{conf};
    my($remoteSend, $remoteDir, $remoteDirDaemon);

    alarm($conf->{ClientTimeout});
    if ( $t->{type} eq "restore" ) {
	$remoteSend       = 0;
	($remoteDir       = "$t->{shareName}/$t->{pathHdrDest}") =~ s{//+}{/}g;
	($remoteDirDaemon = "$t->{shareName}/$t->{pathHdrDest}") =~ s{//+}{/}g;
	$remoteDirDaemon  = $t->{shareNameSlash}
				if ( $t->{pathHdrDest} eq ""
			 		      || $t->{pathHdrDest} eq "/" );
    } else {
	$remoteSend      = 1;
	$remoteDir       = $t->{shareNameSlash};
	$remoteDirDaemon = ".";
    }
    if ( $t->{XferMethod} eq "rsync" ) {
	#
	# Run rsync command
	#
	my $str = "Running: "
	        . $t->{bpc}->execCmd2ShellCmd(@{$t->{rsyncClientCmd}})
		. "\n";
	$t->{XferLOG}->write(\$str);
	$rs->remoteStart($remoteSend, $remoteDir);
    } else {
	#
	# Connect to the rsync server
	#
	if ( defined(my $err = $rs->serverConnect($t->{hostIP},
					     $conf->{RsyncdClientPort})) ) {
	    $t->{hostError} = $err;
	    my $str = "Error connecting to rsync daemon at $t->{hostIP}"
		    . ":$conf->{RsyncdClientPort}: $err\n";
	    $t->{XferLOG}->write(\$str);
	    return;
	}
	#
	# Pass module name, and follow it with a slash if it already
	# contains a slash; otherwise just keep the plain module name.
	#
	my $module = $t->{shareName};
	$module = $t->{shareNameSlash} if ( $module =~ /\// );
	if ( defined(my $err = $rs->serverService($module,
                                             $conf->{RsyncdUserName},
                                             $conf->{RsyncdPasswd},
                                             $conf->{RsyncdAuthRequired})) ) {
	    my $str = "Error connecting to module $module at $t->{hostIP}"
		    . ":$conf->{RsyncdClientPort}: $err\n";
	    $t->{XferLOG}->write(\$str);
	    $t->{hostError} = $err;
	    return;
	}
	$rs->serverStart($remoteSend, $remoteDirDaemon);
    }
    my $error = $rs->go($t->{shareNameSlash});
    $rs->serverClose();

    #
    # TODO: generate sensible stats
    # 
    # $rs->{stats}{totalWritten}
    # $rs->{stats}{totalSize}
    #
    my $stats = $rs->statsFinal;
    if ( !defined($error) && defined($stats) ) {
	$t->{xferOK} = 1;
    } else {
	$t->{xferOK} = 0;
    }
    $t->{xferErrCnt} = $stats->{remoteErrCnt};
    $t->{byteCnt}    = $stats->{childStats}{TotalFileSize}
		     + $stats->{parentStats}{TotalFileSize};
    $t->{fileCnt}    = $stats->{childStats}{TotalFileCnt}
		     + $stats->{parentStats}{TotalFileCnt};
    my $str = "Done: $t->{fileCnt} files, $t->{byteCnt} bytes\n";
    $t->{XferLOG}->write(\$str);
    #
    # TODO: get error count, and call fio to get stats...
    #
    $t->{hostError} = $error if ( defined($error) );

    if ( $t->{type} eq "restore" ) {
	return (
	    $t->{fileCnt},
	    $t->{byteCnt},
	    0,
	    0
	);
    } else {
	return (
	    0,
	    $stats->{childStats}{ExistFileCnt}
		+ $stats->{parentStats}{ExistFileCnt},
	    $stats->{childStats}{ExistFileSize}
		+ $stats->{parentStats}{ExistFileSize},
	    $stats->{childStats}{ExistFileCompSize}
		+ $stats->{parentStats}{ExistFileCompSize},
	    $stats->{childStats}{TotalFileCnt}
		+ $stats->{parentStats}{TotalFileCnt},
	    $stats->{childStats}{TotalFileSize}
		+ $stats->{parentStats}{TotalFileSize},
	);
    }
}

sub setSelectMask
{
    my($t, $FDreadRef) = @_;
}

sub errStr
{
    my($t) = @_;

    return $RsyncLibErr if ( !defined($t) || ref($t) ne "HASH" );
    return $t->{_errStr};
}

sub xferPid
{
    my($t) = @_;

    return -1;
}

sub logMsg
{
    my($t, $msg) = @_;

    push(@{$t->{_logMsg}}, $msg);
}

sub logMsgGet
{
    my($t) = @_;

    return shift(@{$t->{_logMsg}});
}

#
# Returns a hash ref giving various status information about
# the transfer.
#
sub getStats
{
    my($t) = @_;

    return { map { $_ => $t->{$_} }
            qw(byteCnt fileCnt xferErrCnt xferBadShareCnt xferBadFileCnt
               xferOK hostAbort hostError lastOutputLine)
    };
}

sub getBadFiles
{
    my($t) = @_;

    return @{$t->{badFiles}};
}

1;