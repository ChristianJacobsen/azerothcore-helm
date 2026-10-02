# renovate: datasource=docker depName=library/mysql
ARG MYSQL_IMAGE=mysql:9.7.2
FROM ${MYSQL_IMAGE}
LABEL org.opencontainers.image.description="MySQL for the azerothcore chart, without gosu and MySQL Shell"
# The chart starts MySQL as the mysql user, so the entrypoint never calls gosu.
# gosu and MySQL Shell carry nearly all scanner findings of the image.
RUN microdnf remove -y mysql-shell \
 && microdnf update -y \
 && microdnf clean all \
 && rm /usr/local/bin/gosu
USER mysql
