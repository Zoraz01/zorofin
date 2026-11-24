// Generate a portable Swift regression fixture from the existing web rules.
const fs = require('node:fs');
const path = require('node:path');
const {select} = require('../../../branding/zorofin-live-events.js');
const now = Date.parse('2026-10-12T18:00:00Z');
let serial = 0;
function channel(name, patch = {}, extra = {}) {
  return {Id: 'channel-' + (++serial), Name: 'Fixture Sports', Type: 'TvChannel', ChannelNumber: String(serial),
    CurrentProgram: {Name: name, StartDate: new Date(now-3600000).toISOString(), EndDate: new Date(now+3600000).toISOString(), ...patch}, ...extra};
}
const cases = [];
function add(name, channels) { cases.push({name, channels, expected: select(channels, now).map(e => ({id: e.id, title: e.name, sport: e.kind, competition: e.competition}))}); }
add('ranking and CFL', ['Cricket','Soccer','NBA Basketball','NFL Football','CFL Football','Baseball','NHL Hockey','Tennis','Golf','Formula One','Boxing','Opening Ceremony'].map(x => channel('Live: '+x)));
for (const name of ['SEC Now','B1G Live','MLB Now','MLB Tonight','NBA Today','NFL Live','SportsCenter','Premier League Live','Big Day With Peter Schrager','Tiki + Tierney','CPL Matchday Live','Monday Night Countdown','College Football Highlights','Nuggets Postgame Live']) add('exclude '+name, [channel('Live: '+name+' — Alpha Team vs Beta Team', {IsSports:true})]);
for (const name of ['Law & Order','College Football','US| UFC HD','NBA TV','ESPN News']) add('sports flag is insufficient '+name, [channel(name,{IsSports:true})]);
for (const [label, patch] of Object.entries({repeat:{IsRepeat:true}, notLive:{IsLive:false}, noEnd:{EndDate:null}, invalidStart:{StartDate:'invalid'}, future:{StartDate:new Date(now+1000).toISOString()}, ended:{EndDate:new Date(now).toISOString()}, allDay:{StartDate:new Date(now-86400000).toISOString()}, discussion:{Overview:'A preview show with studio analysis.'}})) add(label,[channel('Live: Soccer',patch)]);
add('explicit live flag',[channel('Soccer',{IsLive:true})]);
add('unproven scoreboard suffix',[channel('Live: Premier League Soccer — Newcastle United vs Coventry City',{Overview:'An unrelated match.'})]);
add('grounded scoreboard suffix',[channel('Live: Premier League Soccer — Newcastle United vs Coventry City',{Overview:'Coventry City hosts Newcastle United.'})]);
add('overlapping team evidence',[channel('Live: Soccer — York vs New York',{Overview:'New York plays today.'})]);
const game = channel('Live: NFL Football — Alpha Team vs Beta Team',{Overview:'Alpha Team hosts Beta Team.'});
add('favorite simulcast wins',[game,{...game,Id:'favorite',Name:'Other Network',UserData:{IsFavorite:true}}]);
add('different windows stay separate',[game,{...game,Id:'later',CurrentProgram:{...game.CurrentProgram,EndDate:new Date(now+7200000).toISOString()}}]);
add('generic competitions stay separate',[channel('Live: College Football'),channel('Live: College Football')]);
add('event labels',[channel('Live: Opening Ceremony'),channel('Live: Something'),channel('Live: Alpha Team vs Beta Team')]);
add('Championship guide labels', ['Live: EFL Championship','Live: English League Championship','Live: English Championship'].map(name => channel(name)));
add('channel branding is not an event',[channel('Fixture Sports',{IsLive:true})]);
add('unicode teams',[channel('Live: Soccer — Bodø Glimt vs København',{Overview:'København visits Bodø Glimt.'})]);
fs.writeFileSync(path.join(__dirname,'../Core/Tests/ZorofinCoreTests/Fixtures/live-events-parity.json'), JSON.stringify({now:new Date(now).toISOString(),cases},null,2)+'\n');
console.log(`Generated ${cases.length} web/native parity cases.`);
