#!perl

package Test::CPANpm::Fake;

use strict;
use warnings;
use CPAN;
use Cwd qw(abs_path getcwd);
use File::Path qw(rmtree mkpath);
use File::Temp qw(mktemp tempdir tempfile);
use File::Basename;
use Exporter qw(import);
use CPAN::Config;

our @EXPORT = qw(get_prereqs run_with_fake_modules dist_dir change_std restore_std);

sub run_with_fake_modules (&@);
sub change_std;
sub restore_std;

return 1;

sub _wrap {
    my($sub, $wrapper) = @_;
    my $wrap_call;

    {
        no strict 'refs';
        no warnings 'redefine';
        my $sub_ref = \&{$sub};
        $wrap_call = sub { $wrapper->($sub_ref, @_); };
        *{$sub} = $wrap_call;
    }

    return $wrap_call;
}


sub _unsat_prereq {
    my($orig, $self) = @_;
    if(my $prereq_pm = $self->prereq_pm) {
        # The empty string prevents "make" from actually running
        return('', keys(%$prereq_pm));
    } else {
        return;
    }
}

sub dist_dir_mb {
    my $root = shift;
    my $here = getcwd();
    my $pre = mktemp("XXXXXX");
    my $name = "$pre-0";
    chdir($root);
    system("./Build", "dist_name=$pre", "dist_version=0", "distdir");
    chdir($here);
    return "$root/$name";
}

sub dist_dir_mm {
    my $root = shift;
    my $here = getcwd();
    chdir($root);
    my $name = mktemp("XXXXXXX") . "-0";
    my $make = $CPAN::Config->{'make'};
    system($make, "DISTVNAME=$name", "distdir");
    chdir($here);
    return "$root/$name";
}

sub dist_dir {
    my $dir = shift;
    $dir = abs_path($dir);
    if(-e "$dir/Build") {
        return dist_dir_mb($dir);
    } elsif(-e "$dir/Makefile") {
        return dist_dir_mm($dir);
    } else {
        die "There is no 'Build' or 'Makefile' script in $dir!";
    }
}

sub make_fake_module {
    my($lib, $package, $good) = @_;
    
    $good = $good ? 1 : 0;
    my $pathname = "$lib/$package.pm";
    $pathname =~ s{::}{/}g;
    my $dir = dirname($pathname);
    mkpath($dir);
    open(my $fh, ">$pathname") or die "write $pathname: $!";
    print $fh "$good;\n";
    close $fh;
    
    if($ENV{DEBUG_TEST_CPAN}) {
        print "$package => $pathname\n";
    }
    
    return $pathname;
}

sub setup_fake_modules {
    my %modules = @_;
    
    my $fake_dir = tempdir(CLEANUP => 1);
    
    while(my($k, $v) = each(%modules)) {
        make_fake_module($fake_dir, $k, $v);
    }

    return $fake_dir;
}

sub unshift_inc {
    my $fake_dir = shift;
    @INC = ($fake_dir, @INC);
    
    # if we use PERL5LIB here, Module::Build usurps our changes...
    if($ENV{PERL5OPT}) {
        $ENV{PERL5OPT} .= " -I$fake_dir"
    } else {
        $ENV{PERL5OPT} = "-I$fake_dir";
    }

    if($ENV{DEBUG_TEST_CPAN}) {
        print "PERL5OPT = $ENV{PERL5OPT}";
    }
}

sub run_with_fake_modules (&@) {
    my($run, %modules) = @_;

    my($out, $in) = change_std;
    
    my $fake_dir = setup_fake_modules(%modules);
    
    local @INC = @INC;
    my $perl5opt = $ENV{PERL5OPT};
    local $ENV{PERL5OPT};
    $ENV{PERL5OPT} = $perl5opt if($perl5opt);
    unshift_inc($fake_dir);
    
    my $rv = $run->();
    restore_std($out, $in);
    return $rv;
}

sub change_std {
    my($out, $in);
    
    open($in, "<&", *STDIN) if fileno(STDIN);
    open($out, ">&", *STDOUT) if fileno(STDOUT);

    if($ENV{DEBUG_TEST_CPAN}) {
        open(STDOUT, ">&", *STDERR);
    } else {
        open(STDOUT, ">&", scalar tempfile);
        open(STDIN, "<&", scalar tempfile);
    }
    
    return($out, $in);
}

sub restore_std {
    my($out, $in) = @_;
    open(STDIN, "<&", $in) if defined $in;
    open(STDOUT, ">&", $out) if defined $out;
}

sub get_prereqs {
	my $dist_dir = shift or die 'dist_dir is required!';
	my @followed;

    my($out, $in) = change_std();

	{
            local *CPAN::Distribution::follow_prereqs;
            local *CPAN::Distribution::unsat_prereq;

            # this is paranoid... in case DEBUG_TEST_CPAN gets changed in here,
            # we want our old one back when it's done.

            my $test_cpan = $ENV{DEBUG_TEST_CPAN};
        
            local $ENV{DEBUG_TEST_CPAN};
            
            if($test_cpan) {
                $ENV{DEBUG_TEST_CPAN} = $test_cpan;
            }
                
            if($ENV{DEBUG_TEST_CPAN}) {
                warn "CPAN.pm version: $CPAN::VERSION\n";
            }

            _wrap('CPAN::Distribution::follow_prereqs', sub { @followed = splice(@_, 3); });
            _wrap('CPAN::Distribution::unsat_prereq', \&_unsat_prereq);
            my $here = getcwd();
            chdir($dist_dir);
            my $d = CPAN::Distribution->new(build_dir => $dist_dir, ID => $dist_dir, archived => 'Fake', unwrapped => 'Yes');
            $d->make;
            chdir($here);
            rmtree($dist_dir) unless $ENV{DEBUG_TEST_CPAN} && $ENV{DEBUG_TEST_CPAN} != 2;
	}

    restore_std($out, $in);
	
	return @followed;
}

# perl -MCPAN -e 'chdir("dev/DBIx-Transaction"); my $d = CPAN::Distribution->new(build_dir => "/home/faraway/dev/DBIx-Transaction", ID => "dev/DBIx-Transaction"); print $d->test'
