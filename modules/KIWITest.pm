#================
# FILE          : KIWITest.pm
#               :
# PROJECT       : KIWI
# COPYRIGHT     : (c) 2008 Novell inc. All rights reserved
#               :
# AUTHOR        : Pavel Sladek <psladek@suse.cz>
#               : Pavel Nemec  <pnemec@suse.cz>
#               :
# BELONGS TO    : Testing framework for Images
#               :
# DESCRIPTION   : This module launches a given test, checks 
#               : prerequisities described in xml file and 
#               : returns results
#               :
# STATUS        : Development
#----------------
package KIWITest;
#==========================================
# Modules
#------------------------------------------
require Exporter;
use strict;
use XML::LibXML;
use KIWITestResult;

#==========================================
# Exports
#------------------------------------------
our @ISA    = qw (Exporter);
our @EXPORT	= (
	'run',
	'getOverallMessage',
	'getName','getDescription','getSummary',
	'getAllResults','getResultStatus','getResultState',
	'getResultCommand','getResultMessage',
	'getResultErrorState','getResultCount'
);

#==========================================
# onstructor
#------------------------------------------
sub new {
	# ...
	# Create new KIWITest object which allows to run
	# integrity checks on a given image root tree
	# ---
	#==========================================
	# Object setup
	#------------------------------------------
	my ($class,$testpathname,$chroot,$schema,$manager,$tmpdir)  = @_;
	my $self = {};
	if (!defined $tmpdir) {
		$tmpdir = "/tmp";
	}
	if ((!defined $schema) || (! -f $schema)) {
		return undef;
	}
	if (!defined $testpathname)	{
		return undef;
	}
	if (!defined $chroot) {
		return undef;
	}
	if (!defined $manager) {
		return undef;
	}
	$manager -> switchToChroot();
	$self->{MANAGER}=$manager;
	$self->{CHROOT_TMP}=$tmpdir;
	$self->{CHROOT}=$chroot;
	$self->{TEST_PATH}=$testpathname;
	if ($self->{TEST_PATH}=~m@^(.*)/(.*?)$@) {
		$self->{DNAME}=$2;
		$self->{TEST_BASE_PATH}=$1;
	} else {
		$self->{DNAME}=$self->{TEST_PATH};
		$self->{TEST_BASE_PATH}='.';
	}
	$self->{XML_DESC} = "no description";
	$self->{XML_NAME} = "no name";
	undef $self->{XML_SUMM};
	
	$self->{XML_FILE} = trimpath ($self->{TEST_PATH}."/test-case.xml");    
	$self->{RNG_FILE} = $schema;
	undef $self->{TEST_RESULT};
	undef $self->{XML_ROOT_NODE};    					   
	undef $self->{TEST_RESULT_STATUS};
	#1 failed xml, 2 - failed reqs, 3 - failed tests 
	$self->{TEST_RESULT_STATE} = 0;
	undef $self->{TEST_OVERALL_MESSAGE};
	bless $self;
	return $self;
}

#==========================================
# trimpath
#------------------------------------------
sub trimpath {
	my ($path)=@_;
	$path=~s@/+@/@g;
	$path=~s@/$@@g;
	return $path;
}

#==========================================
# run
#------------------------------------------
sub run {
	# ...
	# main subroutine to run a specific 
	# test describen in $xmlfile onto $chroot
	# ---
	my ($self) = @_;
	my $tr=KIWITestResult->new();
	$self->{TEST_RESULT_STATUS}=0;  # assume all ok
	$self->KIWITest::loadXML();
	unless ($self->{TEST_RESULT_STATUS}) {
		$self->KIWITest::checkRequirements();
		unless ($self->{TEST_RESULT_STATUS}) {
			$self->KIWITest::runTests();	
		}	
	}
	return $self->{TEST_RESULT_STATUS};
}

#==========================================
# loadXML
#------------------------------------------
sub loadXML {
	# ...
	# load xml file and validate it
	# ---
	my ($self) = @_;
	my $xs;
	my $xd;
	my $xslcfg_root_node;
	my $output='';
	my @results=();
	my $xslcfg;
	eval{
		$xs=XML::LibXML->new();
		$xslcfg = $xs->parse_file( $self->{XML_FILE} );
		$xslcfg_root_node= $xslcfg->getDocumentElement;
	};
	if ( $@ ) {
		$output=sprintf("error reading xml file '$self->{XML_FILE}' :\n");
		$output=$output.sprintf("$@.\n");
		$self->{TEST_RESULT_STATUS}=1;
		my $result=KIWITestResult->new();
		$result->setCommand("open '$self->{XML_FILE}'");;
		$result->setMessage($output);
		$result->setErrorState(1);
		@results=(@results,$result);
	}
	unless ($self->{TEST_RESULT_STATUS}) {
		eval {
			$xd = XML::LibXML::RelaxNG -> new ( location => $self->{RNG_FILE} );
		};
		if ( $@ ) { 
			$output=sprintf("error reading RNG template '$self->{RNG_FILE}'\n");
			$output=$output.sprintf("$@.\n");
			$self->{TEST_RESULT_STATUS}=1;
			my $result=KIWITestResult->new();
			$result->setCommand("open '$self->{RNG_FILE}'");
			$result->setMessage($output);
			$result->setErrorState(1);
			@results=(@results,$result);
		}
	}
	unless ($self->{TEST_RESULT_STATUS}) {
		eval{ $xd->validate($xslcfg);};
		if ( $@ ){ 
			$output=sprintf("error, xml file '$self->{XML_FILE}' invalid\n");
			$output=$output.sprintf("$@.\n");
			$self->{TEST_RESULT_STATUS}=1;
			my $result=KIWITestResult->new();
			$result->setCommand("validate '$self->{XML_FILE}'");
			$result->setMessage($output);
			$result->setErrorState(1);
			@results=(@results,$result);
		}
	}
	if ($self->{TEST_RESULT_STATUS}) {
		$self->{TEST_RESULT}=\@results;
		$self->{TEST_RESULT_STATE}=1;
	} else {
		$self->{XML_ROOT_NODE}=$xslcfg_root_node;
		$self->{XML_NAME}= $xslcfg_root_node -> getAttribute('name');
		$self->{XML_SUMM}= $xslcfg_root_node -> getAttribute('summary');
		$self->{XML_DESC}= $xslcfg_root_node -> getAttribute('description');
	}
	return $self->{TEST_RESULT_STATUS};
}

#==========================================
# checkRequirements
#------------------------------------------
sub checkRequirements {
	# ...
	# test prerequisities defined in <req> </req>
	# ---
	my ($self) = @_;
	my $output='';
	my @results=();
	my $result=KIWITestResult->new();  #one result for all requirements
	my @reqs= $self->{XML_ROOT_NODE} -> getChildrenByTagName ('requirements')
		-> get_node(1) -> getChildrenByTagName ('req');
	foreach my $req (@reqs) {
		my $type=$req->getAttribute('type');
		my $reqrelpathname=$req->textContent;
		my $reqpathname=$self->{CHROOT}.$reqrelpathname;
		my $ok=0;
		if  ($type eq 'file') {
			# test file existence (link, file (bin or plain)
			if (-f $reqpathname) {$ok=1;}
			if (-l $reqpathname) {$ok=2;}
		} elsif ($type eq 'directory') {
			# test directory existence
			if (-d $reqpathname) {$ok=3;}
		} elsif ($type eq 'package') {
			# test if rpm package is present in chroot
			my $manager = $self->{MANAGER};
			if (! $manager -> setupPackageInfo ( $reqrelpathname )) {
				# package is installed...
				$ok = 4;
			}
		}
		if ($ok==0) {
			my $result=KIWITestResult->new();
			$result->setCommand("requirements test (in '$self->{CHROOT}')");
			$output=sprintf("missing %-10s  $reqrelpathname","$type");
			$result->setMessage($output);
			$result->setErrorState(1);
			$self->{TEST_RESULT_STATUS}=1;
			@results=(@results,$result);
		}
	}
	if ($self->{TEST_RESULT_STATUS}) {
		$self->{TEST_RESULT}=\@results;
		$self->{TEST_RESULT_STATE}=2;
	}
	return $self->{TEST_RESULT_STATUS};
}

#==========================================
# runtTests
#------------------------------------------
sub runTests {
	# ...
	# run scripts and gather results
	# ---
	my ($self) = @_;
	my $output='';
	my @results=();
	my $returnvalue;
	my @scripts=$self->{XML_ROOT_NODE}-> getChildrenByTagName ('test');
	foreach my $script (@scripts) {
		my $place=  $script -> getAttribute('place');
		my $file=   $script -> getChildrenByTagName ('file')
			-> get_node(1) -> textContent();
		my $path;
		my $params='';
		# /.../
		# get path from <path> tag - if no path specified, path to xml
		# is used, '.' is expanded to the same target as well
		# ---
		my $params_node= $script -> getChildrenByTagName ('params');
		foreach my $element ($params_node->get_nodelist() ) {
			$params=$params." ".$element -> textContent();}    
			my $path_node= $script -> getChildrenByTagName ('path');
		if ( $path_node->size() ) {
			$path=   $path_node -> get_node(1) -> textContent();
			$path=~s/^\./$self->{TEST_PATH}/;
		} else {
			$path=$self->{TEST_PATH};
		} 
		$params=~s/CHROOT/$self->{CHROOT}/g;
		$path=trimpath($path);
		my $ok=0;
		my $cmd;
		if ($place eq 'extern') {  #run script directly
			$cmd=$path."/".$file." $params 2>&1";
			$output=`$cmd`;  #run the command
			$returnvalue=$?;
		}elsif ($place eq 'intern') { #copy and add chroot to cmd
			$ok=1;
			my $scrpathname=$path."/".$file;
			my $chrootpath=trimpath($self->{CHROOT}.$self->{CHROOT_TMP});
			my $chrootpathname=$chrootpath."/".$file;
			my $o=`cp $scrpathname $chrootpath 2>&1`;
			my $r=$?;
			if ( $r ){ #couldn't copy 
				$output=sprintf(
					"error, copying of $scrpathname to $chrootpath failed:\n"
				);
				$output=$output.sprintf("$o\n");
				$returnvalue=$r;
			} else {
				$cmd = "chroot ".$self->{CHROOT}." ".$self->{CHROOT_TMP}."/";
				$cmd.= $file." ".$params." 2>&1";
				$output=`$cmd`;
				$returnvalue=$?;
			}
			$o=`rm $chrootpathname 2>&1`;
			$r=$?;
			if ( $r ) { 
				$output=$output.sprintf (
					"\n%s can't delete file '$chrootpathname' afterwards: \n",
					$returnvalue ? 'Also' : 'But'
				);
				$output=$output.sprintf("$o\n");
				$output=$output.sprintf("=> failed.\n");
				$returnvalue=$r;
			}
		}  
		#process error status
		if ($returnvalue == -1) {
			$output="failed to execute: $cmd\n";
		} elsif ($returnvalue & 127) {
			$output=sprintf(
				"$cmd died with signal %d, %s coredump\n",
				($returnvalue & 127), ($returnvalue & 128) ? 'with' : 'without'
			);
		} else {
			$returnvalue=$returnvalue>>8;
		}
		my $result=KIWITestResult->new(); 
		$result->setCommand($cmd);
		$result->setMessage($output);
		$result->setErrorState($returnvalue);
		if ($returnvalue != 0 ) {
			$self->{TEST_RESULT_STATUS}=1;
			$self->{TEST_RESULT_STATE}=3;
		}
		@results=(@results,$result);
	}
	$self->{TEST_RESULT}=\@results;
	return $self->{TEST_RESULT_STATUS};
}

#==========================================
# getOverallMessage
#------------------------------------------
sub getOverallMessage {
	# ...
	# Returns a message formated for direc output
	# ---
	my ($self) = @_;
	my $sta = $self->{TEST_RESULT_STATE};
	my $message;
	if ($sta==0) { #all ok
		$message="Test '$self->{TEST_PATH}' ($self->{XML_SUMM})";
		$message.=" - passed\n";
	} elsif ($sta==1) {
		# xml validation failed
		my $result=pop @{$self->{TEST_RESULT}};
		my $msg=$result->getCommand();
		$message="Test '$self->{TEST_PATH}' ";
		$message.=" - xml operation <$msg> failed  :\n";
		$message.=" ";
		$message.=$result->getMessage(); 
		$message.="\n";
	} elsif ($sta==2) {
		# request failed
		my @results=@{$self->{TEST_RESULT}};
		my $s="";
		if (@results>1) {$s="s"};
		$message="Test '$self->{TEST_PATH}' ($self->{XML_SUMM})";
		$message.=" - requirement$s failed (in $self->{CHROOT})  :\n";
		foreach my $result (@results) {
			$message.=" ";
			$message.=$result->getMessage(); 
			$message.="\n";
		} 
	} elsif ($sta==3) {
		# test run failed
		my @results=@{$self->{TEST_RESULT}};
		my $s="";
		if (@results>1) {$s="s"};
		$message="Test '$self->{TEST_PATH}' ($self->{XML_SUMM})";
		$message.=" - test$s failed  :\n";
		foreach my $result (@results) {
			my $err=$result->getErrorState();
			if ($err) {
				$message.="--------,\n";
				$message.="command : [".$result->getCommand()."]\n";
				$message.="--------´\n";
				$message.=$result->getMessage(); 
				$message.="\n";
				#$message.="----------,\n";
				$message.="exit code : $err\n";
				$message.="----------´\n";
			}
		} 
	}
	return ("$message\n");	
}

#==========================================
# getName
#------------------------------------------
sub getName {
	# ...
	# Returns the test name, as specified
	# in the xml definition file
	# ---
	my ($self) = @_;
	return $self->{XML_NAME}
}

#==========================================
# getSummary
#------------------------------------------
sub getSummary {
	# ...
	# Returns the test summary, as specified
	# in the xml definition file
	# ---
	my ($self) = @_;
	return $self->{XML_SUMM}
}

#==========================================
# getDescription
#------------------------------------------
sub getDescription {
	# ...
	# Returns the test description, as specified
	# in the xml definition file
	# ---
	my ($self) = @_;
	return $self->{XML_DESC}
}

#==========================================
# getAllResults
#------------------------------------------
sub getAllResults {
	# ...
	# Returns results of the test as a list of
	# KIWITestResult objects containing {CMD}, {ERR}, {OUTPUT} strings
	# ---
	my ($self) = @_;
	return($self->{TEST_RESULT});
}

#==========================================
# getResultStatus
#------------------------------------------
sub getResultStatus {
	# ...
	# Returns overall status of a whole test 
	# 0 - passed, 1 - failed
	# ---
	my ($self) = @_;
	return($self->{TEST_RESULT_STATUS});
}

#==========================================
# getResultState 
#------------------------------------------
sub getResultStatte {
	# ...
	# Returns error state of the whole test 
	# 0 - passed, 1 - failed in xml readin phase
	# 2 - failed in requirements check phase
	# 3 - failed in test scripts phase
	# ---
	my ($self) = @_;
	return($self->{TEST_RESULT_STATE});
}

#==========================================
# getResultsCount 
#------------------------------------------
sub getResultCount {
	# ...
	# Returns number of testparts
	# ---
	my ($self) = @_;
	my $count=@{$self->{TEST_RESULT}};
	return($count);
}

#==========================================
# getResultCmd
#------------------------------------------
sub getResultCommand {
	# ...
	# Returns command of a specified test part
	# ---
	my ($self,$index) = @_;
	if (!defined $index) {return undef;}
	return($self->{TEST_RESULT}->[$index]->{CMD});
}

#==========================================
# getResultOutput 
#------------------------------------------
sub getResultMessage {
	# ...
	# Returns output of a specified test part result
	# ---
	my ($self,$index) = @_;
	if (!defined $index) {return undef;}
	return($self->{TEST_RESULT}->[$index]->{OUTPUT});
}

#==========================================
# getResultErr 
#------------------------------------------
sub getResultErrorState {
	# ...
	# Returns returnvalue of a specified test part result
	# ---
	my ($self,$index) = @_;
	if (!defined $index) {return undef;}
	return($self->{TEST_RESULT}->[$index]->{ERR});
}

1;
