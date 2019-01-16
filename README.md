# docker-cicd-pcf


[![Docker Build Status](https://img.shields.io/docker/build/merrillcorporation/docker-cicd-pcf.svg?style=for-the-badge)](https://hub.docker.com/r/merrillcorporation/docker-cicd-pcf/builds/)


alpine based docker container with pcf tools installed. also has: bash, jq, curl, git, tar, gzip...
Includes a rolloing-deploy.sh script to do a rolling deploy in your foundry.

## versions
manually versioned and latest stored in VERSION file

## getting started
this requires a lot of env vars to work. see example in: tools/deploy-params.json.example

`cp tools/deploy-params.json.example tools/deploy-params.json`

edit your values in the new file.

*NOTE*: these are sensitve values, ignored by github and .dockerignore. if buidling in CI make sure you cleanup after creating the file.

## run
### ./run.sh wrapper script
#### rolling deploy
`./run.sh tools/deploy-params.json`

#### cf commands
example of cf target, any cf command will pass through

`./run.sh cf target`

### docker run example
```
docker run \
            -ti --rm \
            --name pcf-tools \
            mrllsvc/pcf-tools:10 bash
```
