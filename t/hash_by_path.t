use strict;
use warnings;
use FindBin qw/$Bin/;
use Test::More qw/no_plan/;
use Test::Exception;
use Test::utf8;
use Encode qw/decode_utf8/;
use Data::Dumper;

BEGIN {
    # Mocking to allow testing regardless of the user's locale
    require I18N::Langinfo;
    no warnings 'redefine';
    *I18N::Langinfo::langinfo = sub($) {
        return "UTF-8" if $_[0] == I18N::Langinfo::CODESET();
    };
    *CORE::GLOBAL::getpwuid = sub {
        wantarray
            ? ("test", "x", "1000", "1000", "", "", "T\x{c3}\x{a9}st", "/home/test", "/bin/bash")
            : "test";
    };
}

use Data::Dumper;

BEGIN { use_ok 'Gitalist::Git::Repository' }

use Path::Class;
my $gitdir = dir("$Bin/lib/repositories/repo1");

my $repo = Gitalist::Git::Repository->new($gitdir);
my $commit = $repo->get_object('36c6c6708b8360d7023e8a1649c45bcf9b3bd818');
isa_ok($commit, 'Gitalist::Git::Object::Commit');

my $file1 = $commit->get_blob_by_path('file1');
isa_ok($file1, 'Gitalist::Git::Object::Blob');
my $file2 = $commit->get_blob_by_path('dir1/file2');
isa_ok($file2, 'Gitalist::Git::Object::Blob');
dies_ok { $commit->get_blob_by_path('dir1') };
dies_ok { $commit->get_blob_by_path('dir1/dir2/file3') };
