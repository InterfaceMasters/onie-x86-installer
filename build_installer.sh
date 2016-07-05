#!/bin/sh -e

#
# Interface Masters Technologies, Inc. 2016
#

cd components
tar czf ../tmp_archive.tar.gz .
sha1=`sha1sum ../tmp_archive.tar.gz | awk '{ print $1 }'`
sed "s/%%IMAGE_SHA1%%/${sha1}/" < ../unpack_run.sh.tmpl > ../installer.sh
cat ../tmp_archive.tar.gz >> ../installer.sh
rm ../tmp_archive.tar.gz
