#!perl

package Test::CPANpm::Fake;

use strict;
use warnings;
use CPAN;
use Cwd qw(abs_path getcwd);
use File::Path qw(rmtree mkpath);
use File::Temp qw(mktemp tempdir);
use File::Basename;
use Exporter qw(import);
use CPAN::Config;

our @EXPORT = qw(get_prereqs run_with_fake_modules dist_dir);

sub run_with_fake_modules (&@);

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

    my $fake_dir = setup_fake_modules(%modules);
    
    local @INC = @INC;
    local $ENV{PERL5OPT} = defined($ENV{PERL5OPT}) ? $ENV{PERL5OPT} : undef;
    unshift_inc($fake_dir);
    
    $run->();
}

sub get_prereqs {
	my $dist_dir = shift or die 'dist_dir is required!';
	my @followed;

	unless($ENV{DEBUG_TEST_CPAN}) {
            open(OLDSTDOUT, ">&", *STDOUT);
            open(OLDSTDIN, "<&", *STDIN);
            open(STDOUT, ">", "/dev/null");
            close(STDIN);
	}

	{
            local *CPAN::Distribution::follow_prereqs;
            local *CPAN::Distribution::unsat_prereq;

            # this is paranoid... in case DEBUG_TEST_CPAN gets changed in here,
            # we want our old one back when it's done so that our filehandles
            # are restored if they need to be.

            local $ENV{DEBUG_TEST_CPAN} =
                defined $ENV{DEBUG_TEST_CPAN} ?
                $ENV{DEBUG_TEST_CPAN} : undef;

            _wrap('CPAN::Distribution::follow_prereqs', sub { @followed = splice(@_, 3); });
            _wrap('CPAN::Distribution::unsat_prereq', \&_unsat_prereq);
            my $here = getcwd();
            chdir($dist_dir);
            my $d = CPAN::Distribution->new(build_dir => $dist_dir, ID => $dist_dir);
            $d->make;
            chdir($here);
            rmtree($dist_dir) unless $ENV{DEBUG_TEST_CPAN};
	}

	unless($ENV{DEBUG_TEST_CPAN}) {
            open(STDIN, "<&", *OLDSTDIN);
            open(STDOUT, ">&", *OLDSTDOUT);
	}
	
	return @followed;
}

# perl -MCPAN -e 'chdir("dev/DBIx-Transaction"); my $d = CPAN::Distribution->new(build_dir => "/home/faraway/dev/DBIx-Transaction", ID => "dev/DBIx-Transaction"); print $d->test'
