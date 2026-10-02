# renovate: datasource=docker depName=library/python
ARG PYTHON_IMAGE=python:3.14.7-alpine
FROM ${PYTHON_IMAGE}
LABEL org.opencontainers.image.description="Python for the scripts of the azerothcore chart, without pip"
# The scripts of the chart use only the standard library, and the packages
# that pip vendors carry all scanner findings of the image.
RUN apk upgrade --no-cache \
 && python3 -m pip uninstall -y pip \
 && rm -rf /usr/local/lib/python3.*/ensurepip
USER 1000:1000
