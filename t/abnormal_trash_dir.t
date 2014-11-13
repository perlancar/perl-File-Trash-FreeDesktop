#!perl

# this test tries to test some abnormal condition in a trash dir, e.g. missing
# info/, missing files/, etc.

use 5.010;
use strict;
use warnings;

use Test::Exception;
use Test::More 0.96;

use File::chdir;
use File::Path qw(make_path remove_tree);
use File::Slurp::Tiny qw(read_file write_file);
use File::Temp qw(tempdir);
use File::Trash::FreeDesktop;
use SHARYANTO::File::Util qw(file_exists);

my $dir = tempdir(CLEANUP=>1);

$ENV{HOME} = $dir;
$CWD = $dir;
my $trash = File::Trash::FreeDesktop->new;

make_path(".local/share");

subtest "missing info/" => sub {
    remove_tree(".local/share/Trash");
    make_path  (".local/share/Trash");
    lives_ok { $trash->list_contents() };
};

DONE_TESTING:
done_testing;
if (Test::More->builder->is_passing) {
    #diag "all tests successful, deleting test data dir";
    $CWD = "/" unless $ENV{NO_CLEANUP};
} else {
    diag "there are failing tests, not deleting test data dir ($dir)";
}
