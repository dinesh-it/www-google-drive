# ======================================================================== #
# Test suite for WWW::Google::Drive
# ======================================================================== #

use warnings;
use strict;

use FindBin qw( $Bin );
use Test::More;

# set this value if you want to trace the log
my $debug_mode = $ARGV[0] || 0;

my $nof_tests      = 18;
my $nof_live_tests = $nof_tests - 2;
my $testfile       = "$Bin/data/testfile";
plan tests => $nof_tests;

use WWW::Google::Drive;
use Log::Log4perl qw(:easy);

if ($debug_mode) {
    Log::Log4perl->easy_init({level => $DEBUG, layout => "%F{1}:%L> %m%n"});
}

my $gd = WWW::Google::Drive->new();

ok(1, "WWW::Google::Drive loaded ok");

my $file_type = $gd->file_mime_type($testfile);
is($file_type, 'application/octet-stream', "file_mime_type is ok");

SKIP: {
    if (!$ENV{LIVE_TEST}) {
        skip "LIVE_TEST not set, skipping live tests", $nof_live_tests;
    }

    unless (-f "$Bin/client_secret.json") {
        die "You have to copy your client secret json file into t directory and name it as client_secret.json\n";
    }

    $gd = WWW::Google::Drive->new(secret_json => "$Bin/client_secret.json");

    my $test_dir = 'net_gd_extended_test';

    my ($files, $parent) = $gd->children("/$test_dir", {maxResults => 3}, {page => 0},);
    ok(!defined $files, "non-existent path");
    is($gd->error(), "Child $test_dir not found", "error message");

    # Get root id
    ($files, $parent) = $gd->children("/", {maxResults => 3}, {page => 0},);
    is(ref($files), "ARRAY", "children returned ok");

    # Create a new folder for test in the root
    $parent = $gd->create_folder("$test_dir", $parent);
    ok($parent, "New folder created");

    # create/upload a new test file
    my $file_id = $gd->new_file($testfile, $parent, "Its a test file");
    ok(defined $file_id, "upload new file ok");

    # Read Test directory files metaData
    ($files, $parent) = $gd->children("/$test_dir", {maxResults => 3}, {page => 0},);
    is(ref($files), "ARRAY", "children returned ok");

    # download and check the content
    my $file_content = $gd->download($files->[0]->{downloadUrl});
    chomp $file_content;
    is($file_content, "This is a testfile from WWW::Google::Drive.", "Download is fine");

    # update the test file
    $file_id = $gd->update_file($file_id, $testfile);
    ok(defined $file_id, "upload modified file ok");

    ($files, $parent) = $gd->children("/$test_dir");
    is(ref($files), "ARRAY", "children returned ok");

    my $total_files = scalar(@{$files});

    $files = $gd->children_by_folder_id($parent);
    is(ref($files), "ARRAY", "children_by_folder_id returned ok");
    cmp_ok($total_files, '==', scalar(@{$files}), "children_by_folder_id returnded correct values");

    $files = $gd->files({maxResults => 3}, {page => 0});
    is(ref($files), "ARRAY", "files found");

    $files = $gd->search("title = 'testfile'");
    is(ref($files),          "ARRAY",    "search response is ok");
    is($files->[0]->{title}, "testfile", "search response is correct");

    ok($gd->delete($file_id), "file delete ok");

    ok($gd->delete($parent), "folder delete ok");
}
