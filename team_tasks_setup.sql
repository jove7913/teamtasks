-- =====================================================================
--  팀 업무 진척 · 피드백 앱  (Seguimiento de tareas del equipo)
--  Supabase 설정 SQL  — 기존 프로젝트에 `team` 스키마로 추가
--  실행 순서: SQL Editor에 전체 붙여넣기 → Run
--  실행 후: Settings > API > Exposed schemas 에 `team` 추가 (필수!)
-- =====================================================================

create schema if not exists team;

-- ---------------------------------------------------------------------
-- 1. 멤버 (팀원 / 팀장 / 매니저)
--    role: gerente(매니저) · lider(팀장) · miembro(팀원)
--    팀명(team_name)은 자유 입력 — 성형/도장 등 나중에 정하면 됨
--    lider + miembro 합계는 10명까지 (트리거로 제한)
-- ---------------------------------------------------------------------
create table if not exists team.members (
  id          bigint generated always as identity primary key,
  name        text not null,
  team_name   text not null default '',
  role        text not null default 'miembro' check (role in ('gerente','lider','miembro')),
  plant       text not null default '' ,           -- '1', '2', '' (공통)
  pin         text not null default '0000',
  active      boolean not null default true,
  sort_order  int  not null default 100,
  created_at  timestamptz not null default now()
);

create or replace function team.check_member_limit()
returns trigger language plpgsql as $$
begin
  if new.active and new.role <> 'gerente' then
    if (select count(*) from team.members
         where active and role <> 'gerente' and id <> coalesce(new.id, -1)) >= 10 then
      raise exception 'MEMBER_LIMIT: máximo 10 miembros activos (최대 10명)';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_member_limit on team.members;
create trigger trg_member_limit
  before insert or update on team.members
  for each row execute function team.check_member_limit();

-- ---------------------------------------------------------------------
-- 2. 업무
--    status  : planificado · en_curso · completado · retrasado · en_espera
--    priority: urgente · alta · media · baja
-- ---------------------------------------------------------------------
create table if not exists team.tasks (
  id           bigint generated always as identity primary key,
  title        text not null,
  team_name    text not null default '',
  member_id    bigint references team.members(id) on delete set null,   -- 대표 담당자
  member_ids   bigint[] not null default '{}',                             -- 담당자 전체 (협업)
  plant        text not null default '',
  status       text not null default 'planificado'
               check (status in ('planificado','en_curso','completado','retrasado','en_espera')),
  priority     text not null default 'media'
               check (priority in ('urgente','alta','media','baja')),
  start_date   date,
  end_date     date,
  progress     int  not null default 0 check (progress between 0 and 100),
  kpi_target   text not null default '',
  kpi_actual   text not null default '',
  description  text not null default '',
  recur        text not null default 'none'
               check (recur in ('none','daily5','daily6','weekly','monthly')),  -- 반복 주기
  completed_at timestamptz,                                                     -- 실제 완료 시각 (지연일 계산용)
  created_by   bigint references team.members(id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- 이미 tasks 테이블이 있는 경우 (업그레이드용)
alter table team.tasks add column if not exists recur text not null default 'none';
alter table team.tasks add column if not exists completed_at timestamptz;
alter table team.tasks add column if not exists member_ids bigint[] not null default '{}';
notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- 2-1. 반복 업무 인스턴스 (매일/매주/매월 자동 생성되는 체크 항목)
--      앱이 주차를 열 때 해당 주의 인스턴스를 자동 생성 (template_id + due_date 유일)
-- ---------------------------------------------------------------------
create table if not exists team.task_instances (
  id           bigint generated always as identity primary key,
  template_id  bigint not null references team.tasks(id) on delete cascade,
  due_date     date   not null,
  done         boolean not null default false,
  done_at      timestamptz,
  done_by      bigint references team.members(id) on delete set null,
  created_at   timestamptz not null default now(),
  unique (template_id, due_date)
);
create index if not exists idx_ti_due on team.task_instances(due_date);

-- ---------------------------------------------------------------------
-- 2-2. 일정 (달력에 등록하는 이벤트 — 팀장/매니저가 등록, 선택한 멤버와 공유)
-- ---------------------------------------------------------------------
create table if not exists team.events (
  id          bigint generated always as identity primary key,
  title       text not null,
  date        date not null,
  end_date    date not null,
  time        text,
  note        text not null default '',
  member_ids  bigint[] not null default '{}',   -- 공유 대상 (비어 있으면 등록자만)
  created_by  bigint references team.members(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists idx_events_date on team.events(date);

-- ---------------------------------------------------------------------
-- 3. 주간 업데이트 (업무 × 주차 = 1행)  + 매니저 피드백
--    week_key : ISO 주차  예) 2026-W38
--    feedback_type: bien(👍) · ajustar(🔁) · apoyo(🆘) · replanificar(⏰)
-- ---------------------------------------------------------------------
create table if not exists team.weekly_updates (
  id            bigint generated always as identity primary key,
  task_id       bigint not null references team.tasks(id) on delete cascade,
  week_key      text   not null,
  done_text     text   not null default '',   -- 금주 실적
  plan_text     text   not null default '',   -- 차주 계획
  author_id     bigint references team.members(id) on delete set null,
  feedback_type text   check (feedback_type in ('bien','ajustar','apoyo','replanificar')),
  feedback_text text   not null default '',
  feedback_by   bigint references team.members(id) on delete set null,
  feedback_at   timestamptz,
  read_at       timestamptz,                  -- 팀원이 피드백 확인한 시각
  fb_requested  boolean not null default false, -- 팀원이 피드백 요청함 (반복 업무용)
  updated_at    timestamptz not null default now(),
  unique (task_id, week_key)
);

alter table team.weekly_updates add column if not exists fb_requested boolean not null default false;
create index if not exists idx_wu_week on team.weekly_updates(week_key);
create index if not exists idx_tasks_member on team.tasks(member_id);

-- updated_at 자동 갱신
create or replace function team.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

drop trigger if exists trg_tasks_touch on team.tasks;
create trigger trg_tasks_touch before update on team.tasks
  for each row execute function team.touch_updated_at();

drop trigger if exists trg_wu_touch on team.weekly_updates;
create trigger trg_wu_touch before update on team.weekly_updates
  for each row execute function team.touch_updated_at();

-- ---------------------------------------------------------------------
-- 4. 권한 (anon 키 + 앱 내부 PIN 로그인 방식 — 기존 앱들과 동일)
-- ---------------------------------------------------------------------
grant usage on schema team to anon, authenticated;
grant select, insert, update, delete on all tables in schema team to anon, authenticated;
grant usage, select on all sequences in schema team to anon, authenticated;
alter default privileges in schema team grant select, insert, update, delete on tables to anon, authenticated;
alter default privileges in schema team grant usage, select on sequences to anon, authenticated;

alter table team.members        enable row level security;
alter table team.tasks          enable row level security;
alter table team.weekly_updates enable row level security;
alter table team.task_instances enable row level security;
alter table team.events enable row level security;

drop policy if exists members_all on team.members;
drop policy if exists tasks_all   on team.tasks;
drop policy if exists wu_all      on team.weekly_updates;
drop policy if exists ti_all      on team.task_instances;
drop policy if exists ev_all      on team.events;
create policy members_all on team.members        for all to anon, authenticated using (true) with check (true);
create policy tasks_all   on team.tasks          for all to anon, authenticated using (true) with check (true);
create policy wu_all      on team.weekly_updates for all to anon, authenticated using (true) with check (true);
create policy ti_all      on team.task_instances for all to anon, authenticated using (true) with check (true);
create policy ev_all      on team.events         for all to anon, authenticated using (true) with check (true);

-- ---------------------------------------------------------------------
-- 5. 초기 데이터 — 매니저 계정 (PIN은 로그인 후 관리 화면에서 변경)
-- ---------------------------------------------------------------------
insert into team.members (name, team_name, role, pin, sort_order)
select 'Daegon', 'Gerencia', 'gerente', '7913', 0
where not exists (select 1 from team.members where role = 'gerente');

-- 완료 후 확인:
-- select * from team.members;
