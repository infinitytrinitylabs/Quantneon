const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = '/home/runner/work/Quantneon/Quantneon';

function read(relativePath) {
  return fs.readFileSync(path.join(repoRoot, relativePath), 'utf8');
}

test('QualityScoring implements rolling 7-day interaction scoring', () => {
  const source = read('neocity-3d/scripts/social/QualityScoring.gd');

  assert.match(source, /class_name\s+QualityScoring/);
  assert.match(source, /ROLLING_WINDOW_SECONDS\s*:\s*int\s*=\s*7\s*\*\s*24\s*\*\s*60\s*\*\s*60/);
  assert.match(source, /func\s+record_interaction\(/);
  assert.match(source, /func\s+record_shared_event_participation\(/);
  assert.match(source, /func\s+get_resonance_score\(/);
  assert.match(source, /func\s+_prune_old_interactions\(/);
});

test('InstanceRouter supports resonance-based routing and visual cue payloads', () => {
  const source = read('neocity-3d/scripts/networking/InstanceRouter.gd');

  assert.match(source, /class_name\s+InstanceRouter/);
  assert.match(source, /func\s+route_user\(/);
  assert.match(source, /func\s+route_users\(/);
  assert.match(source, /func\s+get_all_instance_cues\(/);
  assert.match(source, /func\s+_build_instance_cue\(/);
  assert.match(source, /"aura_intensity"/);
});

test('VirtualLobby is wired to social clustering services', () => {
  const source = read('neocity-3d/scripts/virtual_lobby.gd');

  assert.match(source, /QualityScoringScript\s*=\s*preload\("res:\/\/scripts\/social\/QualityScoring\.gd"\)/);
  assert.match(source, /InstanceRouterScript\s*=\s*preload\("res:\/\/scripts\/networking\/InstanceRouter\.gd"\)/);
  assert.match(source, /func\s+record_social_interaction\(/);
  assert.match(source, /func\s+_apply_resonance_ambience\(/);
});
