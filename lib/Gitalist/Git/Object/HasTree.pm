package Gitalist::Git::Object::HasTree;
use MooseX::Declare;

role Gitalist::Git::Object::HasTree {
    use MooseX::Types::Common::String qw/NonEmptySimpleStr/;
    use Moose::Autobox;
    use aliased 'Gitalist::Git::Object::Blob';
    use aliased 'Gitalist::Git::Object::Tree';

    has tree => ( isa => 'ArrayRef[Gitalist::Git::Object]',
                  required => 0,
                  is => 'ro',
                  lazy_build => 1 );

    method get_blob_by_path ( NonEmptySimpleStr $path ) {
        $path = [ split('/', $path) ];
        my $object = $self->tree
            ->grep( sub { $_->file eq $path->head } )
                ->shift;

        if ( $path->length == 1 and $object->isa(Blob) ) {
            return $object
        } elsif ( $path->length > 1 and $object->isa(Tree) ) {
            return $object->get_blob_by_path( $path->tail->join('/') );
        } else {
            die "path did not match a blob";
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

=head2 get_blob_by_path(Str $path)

Returns a Blob for the given path.  Throws exception on failure.

=head1 AUTHORS

See L<Gitalist> for authors.

=head1 LICENSE

See L<Gitalist> for the license.

=cut
