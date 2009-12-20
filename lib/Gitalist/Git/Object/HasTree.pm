package Gitalist::Git::Object::HasTree;
use MooseX::Declare;

role Gitalist::Git::Object::HasTree {
    use MooseX::Types::Common::String qw/NonEmptySimpleStr/;
    use Moose::Autobox;

    has tree => ( isa => 'ArrayRef[Gitalist::Git::Object]',
                  required => 0,
                  is => 'ro',
                  lazy_build => 1 );

    method get_blob_by_path ( NonEmptySimpleStr $path ) {
        $path = [ split('/', $path) ];
        my $node = $self->tree->grep(
            sub { $_->file eq $path->head }
        )->shift;

        if ($path->length == 1) {
            # at the end of the path
            if ($node->type eq 'blob') {
                return $node
            } else {
                die "path did not match a blob";
            }
        } else {
            if ($node->type eq 'tree') {
                return $node->get_blob_by_path( $path->tail->join('/') );
            } else {
                die "path did not match a blob";
            }
        }
    }

## Builders
    method _build_tree {
        my $output = $self->_run_cmd(qw/ls-tree -z/, $self->sha1);
        return unless defined $output;

        my @ret;
        for my $line (split /\0/, $output) {
            my ($mode, $type, $object, $file) = split /\s+/, $line, 4;
            my $class = 'Gitalist::Git::Object::' . ucfirst($type);
            push @ret, $class->new( mode => oct $mode,
                                    type => $type,
                                    sha1 => $object,
                                    file => $file,
                                    repository => $self->repository,
                                  );
        }
        return \@ret;
    }

}

1;


1;

__END__

=head1 NAME

Gitalist::Git::Object::HasTree

=head1 SYNOPSIS

    my $tree = Repository->get_object($tree_sha1);

=head1 DESCRIPTION

Role for objects which have a tree - C<Commit> and C<Tree> objects.


=head1 ATTRIBUTES

=head2 tree


=head1 METHODS


=head1 AUTHORS

See L<Gitalist> for authors.

=head1 LICENSE

See L<Gitalist> for the license.

=cut
