-- Supabase SQL Editor에서 프로젝트 관리자(postgres)로 전체 실행합니다.
-- 공개 데이터는 main 한 행뿐입니다. 초안/계정/작성자 식별자는 넣지 않습니다.
-- 재실행은 데이터를 삭제하거나 초기 스냅샷을 덮어쓰지 않습니다.
BEGIN;

CREATE TABLE IF NOT EXISTS public.metal_shared_state (
  id text PRIMARY KEY DEFAULT 'main' CHECK (id = 'main'),
  revision bigint NOT NULL DEFAULT 1 CHECK (revision >= 1),
  payload jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.metal_shared_state ENABLE ROW LEVEL SECURITY;

-- 로그인 없는 공개 편집 모델입니다. 외부 방문자도 RPC로 내용을 바꿀 수 있습니다.
-- 과거 승인 모델의 테이블이 있다면 데이터는 보존하되 클라이언트 접근은 차단합니다.
DO $block$
BEGIN
  IF to_regclass('public.metal_editors') IS NOT NULL THEN
    ALTER TABLE public.metal_editors ENABLE ROW LEVEL SECURITY;
    REVOKE ALL ON public.metal_editors FROM PUBLIC, anon, authenticated;
    REVOKE ALL (user_id) ON public.metal_editors FROM PUBLIC, anon, authenticated;
  END IF;
  IF to_regprocedure('public.metal_is_editor()') IS NOT NULL THEN
    REVOKE ALL ON FUNCTION public.metal_is_editor() FROM PUBLIC, anon, authenticated;
  END IF;
END
$block$;

-- 이전 실행/설정에서 남은 정책도 제거합니다. 이 두 테이블의 정책은 이 파일이 관리합니다.
DO $block$
DECLARE p record;
BEGIN
  FOR p IN SELECT schemaname, tablename, policyname FROM pg_catalog.pg_policies
           WHERE schemaname = 'public'
             AND tablename IN ('metal_shared_state', 'metal_editors')
  LOOP
    EXECUTE format('DROP POLICY %I ON %I.%I', p.policyname, p.schemaname, p.tablename);
  END LOOP;
END
$block$;

REVOKE ALL ON TABLE public.metal_shared_state FROM PUBLIC, anon, authenticated;
-- 테이블 권한과 별도로 저장되는 기존 열 단위 권한도 회수합니다.
REVOKE ALL (id, revision, payload, updated_at) ON public.metal_shared_state
  FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT SELECT ON public.metal_shared_state TO anon, authenticated;
CREATE POLICY metal_public_read ON public.metal_shared_state
  FOR SELECT TO anon, authenticated USING (true);
-- metal_editors에는 클라이언트용 정책/SELECT 권한이 없습니다.

CREATE OR REPLACE FUNCTION public.metal_valid_date(p_text text)
RETURNS boolean
LANGUAGE plpgsql IMMUTABLE SECURITY DEFINER
SET search_path = pg_catalog
AS $fn$
BEGIN
  IF p_text IS NULL OR p_text !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
    RETURN false;
  END IF;
  -- 정규식만으로 통과하는 2026-02-30, 0000-01-01 등은 실제 date 변환에서 거부합니다.
  PERFORM p_text::date;
  RETURN true;
EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow THEN
  RETURN false;
END
$fn$;

CREATE OR REPLACE FUNCTION public.metal_validate_payload(p_payload jsonb)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog
AS $fn$
DECLARE
  v_key text;
  v_value jsonb;
  v_field text;
  v_text text;
  v_week date;
  v_friday date;
BEGIN
  IF jsonb_typeof(p_payload) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'payload must be an object' USING ERRCODE = '22023';
  END IF;
  IF octet_length(p_payload::text) > 2097152 THEN
    RAISE EXCEPTION 'payload exceeds 2 MiB (normalized jsonb text)' USING ERRCODE = '22023';
  END IF;
  IF NOT (p_payload ?& ARRAY['schema','reports','locks','silver','news','latest'])
     OR p_payload - ARRAY['schema','reports','locks','silver','news','latest'] <> '{}'::jsonb
     OR p_payload->'schema' IS DISTINCT FROM '1'::jsonb
     OR jsonb_typeof(p_payload->'reports') IS DISTINCT FROM 'object'
     OR jsonb_typeof(p_payload->'locks') IS DISTINCT FROM 'object'
     OR jsonb_typeof(p_payload->'silver') IS DISTINCT FROM 'object'
     OR jsonb_typeof(p_payload->'news') IS DISTINCT FROM 'array'
     OR jsonb_typeof(p_payload->'latest') IS DISTINCT FROM 'string' THEN
    RAISE EXCEPTION 'invalid payload keys, schema or types' USING ERRCODE = '22023';
  END IF;
  IF (SELECT count(*) FROM jsonb_object_keys(p_payload->'reports')) > 2000
     OR (SELECT count(*) FROM jsonb_object_keys(p_payload->'silver')) > 10000
     OR jsonb_array_length(p_payload->'news') > 500 THEN
    RAISE EXCEPTION 'collection limit exceeded' USING ERRCODE = '22023';
  END IF;

  FOR v_key, v_value IN SELECT key, value FROM jsonb_each(p_payload->'reports') LOOP
    IF NOT public.metal_valid_date(v_key)
       OR jsonb_typeof(v_value) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'invalid report date or object' USING ERRCODE = '22023';
    END IF;
    IF NOT (v_value ?& ARRAY['f','sheet','s','a','c','n'])
       OR v_value - ARRAY['f','sheet','s','a','c','n'] <> '{}'::jsonb THEN
      RAISE EXCEPTION 'invalid report keys' USING ERRCODE = '22023';
    END IF;
    FOREACH v_field IN ARRAY ARRAY['f','sheet','s','a','c','n'] LOOP
      IF jsonb_typeof(v_value->v_field) IS DISTINCT FROM 'string' THEN
        RAISE EXCEPTION 'report values must be strings' USING ERRCODE = '22023';
      END IF;
    END LOOP;
    FOREACH v_field IN ARRAY ARRAY['s','a','c','n'] LOOP
      IF char_length(v_value->>v_field) > 20000 THEN
        RAISE EXCEPTION 'report reason exceeds 20000 characters' USING ERRCODE = '22023';
      END IF;
    END LOOP;
    IF NOT public.metal_valid_date(v_value->>'f') THEN
      RAISE EXCEPTION 'invalid Friday date' USING ERRCODE = '22023';
    END IF;
    v_week := v_key::date;
    v_friday := (v_value->>'f')::date;
    IF extract(isodow FROM v_friday) <> 5 OR v_friday > v_week OR v_week - v_friday > 7 THEN
      RAISE EXCEPTION 'f must be Friday, between report date minus 7 days and report date'
        USING ERRCODE = '22023';
    END IF;
  END LOOP;

  FOR v_key, v_value IN SELECT key, value FROM jsonb_each(p_payload->'locks') LOOP
    IF NOT public.metal_valid_date(v_key)
       OR NOT ((p_payload->'reports') ? v_key)
       OR jsonb_typeof(v_value) IS DISTINCT FROM 'boolean' THEN
      RAISE EXCEPTION 'locks must be booleans for existing reports' USING ERRCODE = '22023';
    END IF;
  END LOOP;
  FOR v_key, v_value IN SELECT key, value FROM jsonb_each(p_payload->'silver') LOOP
    IF NOT public.metal_valid_date(v_key) OR jsonb_typeof(v_value) IS DISTINCT FROM 'number' THEN
      RAISE EXCEPTION 'silver must map valid dates to numbers' USING ERRCODE = '22023';
    END IF;
    IF v_value::numeric <= 0 OR v_value::numeric > 1000000 THEN
      RAISE EXCEPTION 'silver must be greater than 0 and at most 1000000' USING ERRCODE = '22023';
    END IF;
  END LOOP;

  FOR v_value IN SELECT value FROM jsonb_array_elements(p_payload->'news') LOOP
    IF jsonb_typeof(v_value) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'news item must be an object' USING ERRCODE = '22023';
    END IF;
    IF NOT (v_value ?& ARRAY['m','t','u','s','d'])
       OR v_value - ARRAY['m','t','u','s','d'] <> '{}'::jsonb THEN
      RAISE EXCEPTION 'invalid news keys' USING ERRCODE = '22023';
    END IF;
    FOREACH v_field IN ARRAY ARRAY['m','t','u','s','d'] LOOP
      IF jsonb_typeof(v_value->v_field) IS DISTINCT FROM 'string' THEN
        RAISE EXCEPTION 'news values must be strings' USING ERRCODE = '22023';
      END IF;
    END LOOP;
    IF v_value->>'m' NOT IN ('Silver','Aluminium','Copper') THEN
      RAISE EXCEPTION 'invalid news metal' USING ERRCODE = '22023';
    END IF;
    v_text := v_value->>'u';
    -- 빈 값 또는 호스트가 있는 HTTP(S)만 허용. 실제 제어문자/공백/역슬래시는 거부합니다.
    IF v_text <> '' AND (
      v_text !~* '^https?://([a-z0-9]([a-z0-9.-]*[a-z0-9])?|\[[0-9a-f:.]+\])(:[0-9]{1,5})?([/?#][^[:space:]]*)?$'
      OR v_text ~ '[[:cntrl:][:space:]]'
      OR position(chr(92) IN v_text) > 0
    ) THEN
      RAISE EXCEPTION 'news URL must be empty or a safe HTTP(S) URL' USING ERRCODE = '22023';
    END IF;
    v_text := v_value->>'d';
    IF v_text !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}( ([01][0-9]|2[0-3]):[0-5][0-9])?$'
       OR NOT public.metal_valid_date(left(v_text, 10)) THEN
      RAISE EXCEPTION 'invalid news date/time' USING ERRCODE = '22023';
    END IF;
  END LOOP;

  v_text := p_payload->>'latest';
  IF v_text <> '' AND (NOT public.metal_valid_date(v_text)
                       OR NOT ((p_payload->'reports') ? v_text)) THEN
    RAISE EXCEPTION 'latest must be empty or the date of an existing report' USING ERRCODE = '22023';
  END IF;
END
$fn$;

CREATE OR REPLACE FUNCTION public.metal_save(p_expected_revision bigint, p_payload jsonb)
RETURNS SETOF public.metal_shared_state
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog
AS $fn$
DECLARE v_saved public.metal_shared_state;
BEGIN
  IF p_expected_revision IS NULL OR p_expected_revision < 0 THEN
    RAISE EXCEPTION 'expected revision must be a nonnegative integer' USING ERRCODE = '22023';
  END IF;
  PERFORM public.metal_validate_payload(p_payload);

  IF p_expected_revision = 0 THEN
    -- 동시 최초 저장: PK 충돌은 대기 후 DO NOTHING; 한 요청만 revision=1을 얻습니다.
    INSERT INTO public.metal_shared_state (id, revision, payload, updated_at)
      VALUES ('main', 1, p_payload, clock_timestamp())
      ON CONFLICT (id) DO NOTHING
      RETURNING * INTO v_saved;
  ELSE
    -- 원자적 CAS: 행 잠금 대기 이후에도 revision 조건을 다시 검사합니다.
    UPDATE public.metal_shared_state
      SET revision = revision + 1, payload = p_payload, updated_at = clock_timestamp()
      WHERE id = 'main' AND revision = p_expected_revision
      RETURNING * INTO v_saved;
  END IF;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'revision conflict; reload and merge before saving'
      USING ERRCODE = '40001';
  END IF;
  RETURN NEXT v_saved;
  RETURN;
END
$fn$;

-- SECURITY DEFINER는 SQL Editor 관리자 소유로 유지해야 합니다.
-- 고정 search_path와 완전 수식 이름을 사용하고 동적 사용자 입력 SQL은 사용하지 않습니다.
REVOKE ALL ON FUNCTION public.metal_valid_date(text), public.metal_validate_payload(jsonb),
  public.metal_save(bigint, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.metal_save(bigint, jsonb) TO anon, authenticated;

-- postgres_changes 실시간 구독용. 기존 publication/가입 상태를 보존하며 재실행 가능.
DO $block$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_publication WHERE pubname = 'supabase_realtime') THEN
    IF NOT EXISTS (
      SELECT 1 FROM pg_catalog.pg_publication_tables
      WHERE pubname = 'supabase_realtime' AND schemaname = 'public'
        AND tablename = 'metal_shared_state'
    ) THEN
      ALTER PUBLICATION supabase_realtime ADD TABLE public.metal_shared_state;
    END IF;
  ELSE
    RAISE NOTICE 'supabase_realtime publication absent: use polling or enable Supabase Realtime and rerun';
  END IF;
END
$block$;
COMMIT;

-- 수동 검증 (별도 테스트 프로젝트 권장; 아래는 자동 실행되지 않습니다).
-- 실패하는 문장은 각각 별도 BEGIN/ROLLBACK으로 실행하세요. 실패한 트랜잭션은 ROLLBACK 필요.
-- 1. 로그인 없이 공개 읽기:
-- BEGIN; SET LOCAL ROLE anon;
-- SELECT * FROM public.metal_shared_state; -- 0행 또는 main 1행, 성공
-- ROLLBACK;
-- 2. anon 및 authenticated 각각 직접 INSERT/UPDATE/DELETE는 모두 42501:
-- BEGIN; SET LOCAL ROLE anon;
-- UPDATE public.metal_shared_state SET revision = revision + 1 WHERE id = 'main';
-- ROLLBACK;
-- INSERT INTO public.metal_shared_state(payload) VALUES ('{}'); / DELETE FROM ... 도 별도로 검사.
-- 과거 metal_editors가 남아 있다면 SELECT/INSERT 불가도 확인합니다.
-- 3. 익명 정상 저장/오래된 revision/잘못된 payload (JWT/사용자 UUID 불필요):
-- BEGIN;
-- SET LOCAL ROLE anon;
-- SELECT * FROM public.metal_save(
--   coalesce((SELECT revision FROM public.metal_shared_state WHERE id = 'main'), 0),
--   '{"schema":1,"reports":{"2026-10-30":{"f":"2026-10-30","sheet":"test","s":"","a":"","c":"","n":""}},"locks":{"2026-10-30":true},"silver":{"2026-10-30":100},"news":[{"m":"Silver","t":"test","u":"https://example.com/","s":"test","d":"2026-10-30 09:30"}],"latest":"2026-10-30"}'::jsonb
-- ); -- 새 행이면 revision 1, 아니면 기존 +1. ROLLBACK으로 기존 데이터 보존.
-- ROLLBACK;
-- 같은 테스트를 유효 payload + 틀린 expected revision으로 실행: 40001.
-- 유효 payload를 하나씩 바꿔 검사: drafts/user_id 추가, 필드 누락/null/잘못된 타입,
-- 2026-02-30, 금요일 아닌 f, 미래/8일 전 f, 없는 report의 lock/latest,
-- silver 0/1000001/문자열, news m='Gold', u='javascript:alert(1)' 또는 제어문자,
-- d='2026-10-30 24:00', 사유 20001자, 2MiB/2000보고서/10000은값/500뉴스 초과: 22023.
-- 위 저장 테스트를 authenticated 역할로도 반복: 동일하게 성공합니다.
-- 4. 동시성은 두 SQL 세션에서 동일 expected revision + 유효 payload로 실행:
-- 첫 세션 저장 후 COMMIT 전 두 번째는 대기, 첫 COMMIT 후 두 번째는 40001.
-- 빈 테스트 테이블에서도 두 세션 모두 expected=0으로 확인: 성공 1개, 충돌 1개.
-- 충돌 후 같은 payload를 최신 revision으로 무조건 재시도하지 말고 변경 내용을 병합하세요.
-- 5. 별도 브라우저 2개에서 로그인 없이 같은 페이지를 엽니다.
-- 한 창 저장 후 다른 창의 postgres_changes 알림/재조회로 새 revision이 보이는지 확인.
-- WebSocket 연결을 끊어도 주기적 SELECT 폴링으로 최신 상태를 복구하는지 확인.
-- 경고: CAS/검증/백업은 익명 훼손·반복 저장·트래픽/비용 악용을 방지하지 않습니다.
