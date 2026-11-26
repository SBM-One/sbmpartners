"""Offline test of the daily research quota: DENUE screening, the completeness gate (with a redo), and the spot check.
Fake AI, fake web pages, no cost.

  TEST_DATABASE_URL=postgresql:///sbm_test python -m tests.test_quota   (a throwaway database with the migrations)
"""
import datetime as dt
import os
import pathlib
import random
import sys
import tempfile
from types import SimpleNamespace as NS

from agents import quota, strategy, team, teamdb as db
from agents.practice import CriterionScore, Grade, WriterTurn

PAGES = {"https://muebleria.example/nosotros": "Mueblería Norte vende comedores de madera y salas modernas en Monterrey. " * 10,
         "https://muebleria.example/sucursales": "Tenemos doce sucursales en Nuevo León y Coahuila con entrega a domicilio. " * 10,
         "https://news.example/norte": "Mueblería Norte abrió una nueva tienda en San Pedro con línea contemporánea. " * 10}
DENUE = """id,nom_estab,raz_social,nombre_act,per_ocu,municipio,entidad,telefono,correoelec,www
1,MUEBLERIA NORTE,MUEBLERIA NORTE SA DE CV,Comercio al por menor de muebles para el hogar,51 a 100 personas,Monterrey,Nuevo León,8112345678,,www.muebleria-{tag}.example
2,MUEBLERIA NORTE,MUEBLERIA NORTE SA DE CV,Comercio al por menor de muebles para el hogar,11 a 30 personas,San Pedro,Nuevo León,8112345679,,
3,DISTRIBUIDORA SUR,DISTRIBUIDORA SUR SA,Comercio al por mayor de mobiliario y equipo,31 a 50 personas,Puebla,Puebla,2221234567,ventas@sur-{tag}.example,
4,FABRICA DE MUEBLES ROBLE,ROBLE SA,Fabricación de muebles excepto cocinas,101 a 250 personas,Chipilo,Puebla,2229999999,,www.roble-{tag}.example
5,TACOS EL GÜERO,,Restaurantes con servicio de preparación de tacos,0 a 5 personas,Puebla,Puebla,2220000000,,
6,MUEBLES SIN DATOS,,Comercio al por menor de muebles para el hogar,6 a 10 personas,Toluca,México,,,
7,MUEBLES CHICO,,Comercio al por menor de muebles para el hogar,0 a 5 personas,Toluca,México,7221234567,,
"""


def usage():
    return NS(input_tokens=1000, output_tokens=200, cache_creation_input_tokens=0, cache_read_input_tokens=0, server_tool_use=None)


def fake_ai(calls):
    class Ctx:
        def __init__(self, **kw): self.kw = kw
        def __enter__(self):
            msg = NS(model=self.kw["model"], usage=usage(), stop_reason="end_turn", content=[
                NS(type="text", text="Notes.", citations=None),
                NS(type="web_search_tool_result", content=[NS(type="web_search_result", url=u, title="p") for u in PAGES])])
            calls["prompts"].append(self.kw["messages"][0]["content"])
            return NS(get_final_message=lambda: msg)
        def __exit__(self, *a): return False

    def parse(**kw):
        fmt = kw["output_format"]
        if fmt is team.ProspectBrief:
            calls["research"] += 1
            urls = list(PAGES)
            if calls["research"] == 1:   # the first try skims: one page, no buyer search
                facts = [team.Fact(fact="Mueblería Norte vende comedores de madera", source_url=urls[0])]
                out = team.ProspectBrief(summary="Shop.", angle="-", cautions="", fit=3, facts=facts)
            else:
                facts = [team.Fact(fact="Vende comedores de madera y salas modernas en Monterrey", source_url=urls[0]),
                         team.Fact(fact="Doce sucursales en Nuevo León y Coahuila", source_url=urls[1]),
                         team.Fact(fact="Abrió nueva tienda en San Pedro con línea contemporánea", source_url=urls[2])]
                buyer = team.BuyerSearch(how_searched="Their Nosotros page, Google, LinkedIn search for 'compras Mueblería Norte'.",
                                         not_found_reason="No staff named on the site; no public profile found.")
                out = team.ProspectBrief(summary="Shop.", angle="Modern line.", cautions="", fit=4, facts=facts, buyer=buyer)
        elif fmt is strategy.Strategy:
            out = strategy.Strategy(criteria=[strategy.Criterion(key=k, score=4, why="Fits.") for k in strategy.FIT_WEIGHTS],
                                    decision="pursue", reason="Fits.", pitch_angle="Modern.", lead_with=["Dining"],
                                    proof_points=["FSC"], offer=None, objections=[], first_ask="A catalog?",
                                    channel_plan="email", channel_reason="Allowed.")
        elif fmt is team.ChannelPlan:
            out = team.ChannelPlan(steps=[team.PlanStep(day=0, channel="email", purpose="first email")], why="-")
        elif fmt is WriterTurn:
            out = WriterTurn(subject="Comedores", message="Hola, le escribo sobre nuestros comedores para su tienda.", playbook_used=[1])
        elif fmt is Grade:
            out = Grade(criteria=[CriterionScore(key=k, score=9, why="") for k in
                                  ["relevance", "value", "clarity", "ask", "tone", "honesty", "handling"]],
                        feedback="Good.", top_fix="-", playbook_notes="")
        elif fmt is team.ReportText:
            out = team.ReportText(headline="-", summary="-", highlights=["-"], next_week=["-"])
        else:
            raise AssertionError(fmt)
        return NS(model=kw["model"], usage=usage(), stop_reason="end_turn", parsed_output=out)

    return NS(beta=NS(messages=NS(parse=parse, stream=lambda **kw: Ctx(**kw))))


def main():
    url = os.environ.get("TEST_DATABASE_URL")
    if not url:
        sys.exit("Set TEST_DATABASE_URL to a throwaway local database.")
    assert quota.staff_min("251 y más personas") == 251 and quota.staff_min("0 a 5 personas") == 0
    assert quota.supported("Doce sucursales en Nuevo León", PAGES["https://muebleria.example/sucursales"])[0]
    assert not quota.supported("Exporta a Japón y Corea desde 1980", PAGES["https://muebleria.example/sucursales"])[0]

    conn = db.connect(url)
    db.register_team(conn)
    db.all_rows(conn, "update agents set active = true, paused_reason = null, monthly_budget_cents = 100000 where name = any(%s)",
                (list(db.TEAM),))
    db.all_rows(conn, "update tasks set status = 'failed' where status in ('queued', 'running')")   # leftovers of earlier runs
    db.all_rows(conn, "delete from research_checks")
    db.all_rows(conn, "delete from screen_pool")
    db.all_rows(conn, "delete from companies where country = 'MX' and notes like 'From DENUE%%'")   # earlier runs of this test
    db.all_rows(conn, "update research_quota_settings set screen_per_day = 6, research_per_day = 1, spot_check_share = 1, max_redo = 2")
    tag = dt.datetime.now().strftime("%H%M%S%f")
    path = pathlib.Path(tempfile.mkdtemp()) / "denue.csv"
    path.write_text(DENUE.format(tag=tag))
    assert quota.load(conn, path) == 6, "7 establishments, 6 companies (the two Mueblería Norte branches are one)"
    assert quota.load(conn, path) == 0, "loading again adds nothing"
    norte = db.one(conn, "select * from screen_pool where name = 'MUEBLERIA NORTE'")
    assert norte["branches"] == 2 and norte["staff_min"] == 51
    print("ok: DENUE establishments are grouped into companies (branches counted, largest staff band kept)")

    cl = db.one(conn, """insert into clients (name, brief, brief_approved_at, sender_name, sender_company, postal_address, daily_draft_limit)
                         values (%s, %s, now(), 'Santiago', 'SBM Partners', 'Calle 1, Puebla', 10) returning id""",
                (f"Quota test {tag}", db.jsonb({"brand": "Oak Co", "what_they_make": "modern furniture",
                                                 "outreach_language": "Spanish for Mexico"})))["id"]
    camp = db.one(conn, "insert into campaigns (client_id, name, status, channels) values (%s, 'Q', 'live', '{email,whatsapp}') "
                        "returning id", (cl,))["id"]
    if not db.one(conn, "select 1 from playbook_entries where status = 'active'"):
        db.all_rows(conn, "insert into playbook_entries (title, body, status) values ('Keep it short', 'Short.', 'active')")
    day = quota.today()
    out = quota.screen(conn, cl, camp, day, log=lambda m: None)
    assert out["screened"] == 6 and out["picked"] == 1 and out["research_tasks"] == 1, out
    pool = {r["name"]: r for r in db.all_rows(conn, "select * from screen_pool")}
    assert pool["MUEBLERIA NORTE"]["picked"], "the biggest furniture retailer with a website wins"
    assert "maker" in pool["FABRICA DE MUEBLES ROBLE"]["skip_reason"]
    assert "Not a furniture buyer" in pool["TACOS EL GÜERO"]["skip_reason"]
    assert "nothing to research" in pool["MUEBLES SIN DATOS"]["skip_reason"]
    assert "below today's top 1" in pool["DISTRIBUIDORA SUR"]["skip_reason"]
    assert quota.screen(conn, cl, camp, day, log=lambda m: None)["screened"] == 0, "running again the same day adds nothing"
    print("ok: screening scores every company, picks the top one, and logs a reason for each skip")

    calls = {"research": 0, "prompts": []}
    ai = fake_ai(calls)
    team.work_round(conn, ai, workers=1, url=url, log=lambda m: None)
    t = db.one(conn, "select * from tasks where kind = 'research_prospect' and campaign_id = %s", (camp,))
    assert t["status"] == "queued" and "IncompleteResearch" in t["error"], t
    first = db.one(conn, "select * from research_checks where task_id = %s", (t["id"],))
    assert not first["passed"] and len(first["problems"]) >= 2, first["problems"]
    assert not db.one(conn, "select 1 from prospect_strategies where campaign_id = %s", (camp,)), "a failed account is not scored"
    db.all_rows(conn, "update tasks set run_after = now() where id = %s", (t["id"],))
    team.work_round(conn, ai, workers=1, url=url, log=lambda m: None)
    assert "sent back as incomplete" in calls["prompts"][-1], "the redo is told why it was sent back"
    t = db.one(conn, "select * from tasks where id = %s", (t["id"],))
    assert t["status"] == "done" and t["output"]["quota"]["passed"], t
    v = quota.status(conn, day)
    assert (v["screened"], v["picked"], v["researched"], v["passed"], v["failed_attempts"]) == (6, 1, 1, 1, 1), v
    good = db.one(conn, "select * from research_checks where task_id = %s and passed", (t["id"],))
    assert len(good["sources"]) == 3 and good["channels"] == {"email": False, "linkedin": False, "whatsapp": True}, good
    print("ok: a skimmed account fails the gate, is researched again with the reasons, and only counts once it passes")

    rnd = random.Random(1)
    res = quota.spot_check(conn, day, fetch=PAGES.get, rnd=rnd, log=lambda m: None)
    assert res["checked"] == 1 and res["skims"] == 0, res
    db.all_rows(conn, "update research_checks set spot_checked_at = null, spot_result = null where id = %s", (good["id"],))
    res = quota.spot_check(conn, day, fetch=lambda u: "Página sin relación con muebles, solo noticias de futbol. " * 20,
                           rnd=rnd, log=lambda m: None)
    assert res["skims"] == 1, res
    assert db.one(conn, "select 1 from alerts where kind = 'research_skim' and refs->>'key' = %s", (f"skim:{good['id']}",))
    print("ok: the spot check confirms facts on their pages, and flags a skim (with an alert) when they are not there")
    print("All quota tests passed.")


if __name__ == "__main__":
    main()
