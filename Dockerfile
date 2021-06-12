FROM alpine
# docker build -t fooflington/mythic-beasts-dns .
LABEL maintainer="Matthew Slowe <foo@mafoo.org.uk>"
RUN apk --no-cache add perl perl-yaml perl-lwp-protocol-https perl-json perl-uri perl-yaml-tiny perl-www-form-urlencoded
