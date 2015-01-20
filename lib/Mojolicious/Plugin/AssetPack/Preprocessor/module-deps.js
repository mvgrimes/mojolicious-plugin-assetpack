var fs = require('fs');
var ModuleDeps = require('module-deps');
var JSONStream = require('JSONStream');

if (process.argv.length <= 3) process.exit(1);

var md = new ModuleDeps({
  cache: JSON.parse(fs.readFileSync(process.argv[3])),
  globalTransform: JSON.parse(process.env.MODULE_DEPS_TRANSFORMERS || '[]')
});

md.pipe(JSONStream.stringify()).pipe(process.stdout);
md.write(fs.realpathSync(process.argv[2]));

md.end();
