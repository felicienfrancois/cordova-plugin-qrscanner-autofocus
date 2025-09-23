'use strict';

const gulp = require('gulp');
const insert = require('gulp-insert');
const fs= require('fs');

const remap = fs.readFileSync('src/common/src/cordova-remap.js', 'utf-8');

function webpack(config, callback){
  const exec = require('child_process').exec;
  exec(__dirname + '/node_modules/.bin/webpack --config ' + config, (error, stdout, stderr) => {
    console.log(stdout);
    console.log(stderr);
    callback(error);
  });
}

gulp.task('webpack-worker', function(cb){
  webpack('webpack.worker.config.js', cb);
});

gulp.task('webpack-dist', function(cb){
  webpack('webpack.library.config.js', cb);
});

gulp.task('webpack-cordova', function(cb){
  webpack('webpack.cordova.config.js', cb);
});

gulp.task('plugin', function () {
  return gulp.src('dist/plugin.min.js')
  .pipe(insert.prepend(remap))
  .pipe(gulp.dest('src/browser'));
});

gulp.task('www', function () {
  return gulp.src('dist/www.min.js')
  .pipe(insert.prepend(remap))
  .pipe(gulp.dest('www'));
});

gulp.task('default', gulp.series('webpack-worker', 'webpack-dist', 'webpack-cordova', 'plugin', 'www'));
