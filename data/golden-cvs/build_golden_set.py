"""Builds the golden CV set: ten synthetic CVs, each exercising one edge case.

Usage: python3 data/golden-cvs/build_golden_set.py
Needs LibreOffice (soffice) on PATH; on macOS, `sips` makes the scanned PDF.
All people, emails and phone numbers are fictional.
"""
import os
import shutil
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "files")
CSS = """<style>body{font-family:Arial,Helvetica,sans-serif;font-size:10.5pt;line-height:1.35}
h1{font-size:18pt;margin:0}h2{font-size:12pt;border-bottom:1px solid #999;margin-top:14px}
p{margin:3px 0}ul{margin:2px 0 6px 18px;padding:0}td{vertical-align:top}</style>"""


def page(body):
    return f"<html><head><meta charset='utf-8'>{CSS}</head><body>{body}</body></html>"


def role(title, org, dates, bullets):
    items = "".join(f"<li>{b}</li>" for b in bullets)
    return f"<p><b>{title}</b>, {org} | {dates}</p><ul>{items}</ul>"


CVS = {}

# 1. Complete CV (the reference candidate).
SARA = page(
    "<h1>Sara Ahmed</h1>"
    "<p>Senior Salesforce Developer | Cairo, Egypt | sara.ahmed@example.com | +20 100 555 0101</p>"
    "<h2>Summary</h2><p>Salesforce developer with 7 years of experience building Apex, LWC and integration "
    "solutions for Sales and Service Cloud.</p>"
    "<h2>Experience</h2>"
    + role("Senior Salesforce Developer", "Nile Retail Group", "03/2022 - Present",
           ["Led a team of 4 developers delivering Service Cloud for 600 agents.",
            "Built Apex trigger framework and LWC case console; reduced case handling time by 25%.",
            "Designed REST integrations with SAP using Named Credentials and Platform Events."])
    + role("Salesforce Developer", "Delta Consulting", "01/2019 - 02/2022",
           ["Delivered 9 Sales Cloud implementations with Apex, Visualforce and Flow.",
            "Wrote Apex test suites keeping coverage above 90%."])
    + "<h2>Education</h2><p>BSc Computer Science, Cairo University, 2018</p>"
    "<h2>Certifications</h2><ul><li>Salesforce Certified Platform Developer II (2021)</li>"
    "<li>Salesforce Certified Application Architect (2023)</li></ul>"
    "<h2>Skills</h2><p>Apex, LWC, SOQL, Flow, REST APIs, Platform Events, Git, CI/CD with SFDX</p>"
    "<h2>Languages</h2><p>Arabic (native), English (fluent)</p>"
)
CVS["01_sara_ahmed_complete"] = ("pdf", SARA)

# 2. No education section.
CVS["02_omar_khalil_no_education"] = ("docx", page(
    "<h1>Omar Khalil</h1>"
    "<p>Salesforce Integration Developer | Alexandria, Egypt | omar.khalil@example.com | +20 111 555 0202</p>"
    "<h2>Profile</h2><p>Integration-focused developer. MuleSoft and Apex.</p>"
    "<h2>Work history</h2>"
    + role("Integration Developer", "Mediterranean Logistics", "June 2021 - Present",
           ["Built MuleSoft APIs connecting Salesforce to a warehouse system; 2M messages a month.",
            "Wrote Apex callouts and batch jobs for order sync."])
    + role("Junior Developer", "Pharos Software", "July 2019 - May 2021",
           ["Maintained Java services and SQL reports."])
    + "<h2>Skills</h2><p>MuleSoft, Apex, SFDC REST API, Java, SQL, Postman</p>"
    "<h2>Certifications</h2><p>MuleSoft Certified Developer - Level 1 (2022)</p>"
))

# 3. Overlapping job dates.
CVS["03_lina_haddad_overlap"] = ("pdf", page(
    "<h1>Lina Haddad</h1>"
    "<p>Full-stack Developer | Amman, Jordan | lina.haddad@example.com | +962 79 555 0303</p>"
    "<h2>Experience</h2>"
    + role("Salesforce Developer", "Petra Bank", "2020-01 - 2023-06",
           ["Built LWC onboarding wizard and Apex services for KYC checks."])
    + role("Freelance Web Developer", "Self-employed", "2021-03 - 2024-02",
           ["Built JavaScript and React sites for 12 clients."])
    + role("Lead Developer", "Wadi Tech", "2023-05 - Present",
           ["Leads a Salesforce Experience Cloud programme; Apex, LWC, SOQL."])
    + "<h2>Education</h2><p>BSc Software Engineering, University of Jordan, 2019</p>"
    "<h2>Skills</h2><p>Apex, LWC, JavaScript, React, Node.js, SOQL</p>"
))

# 4. Summary contradicts the dated roles (claims 10 years, roles add up to about 5).
CVS["04_youssef_nasser_contradiction"] = ("docx", page(
    "<h1>Youssef Nasser</h1>"
    "<p>Salesforce Technical Lead | Dubai, UAE | youssef.nasser@example.com | +971 50 555 0404</p>"
    "<h2>Summary</h2><p>Technical lead with 10 years of experience in Salesforce delivery.</p>"
    "<h2>Experience</h2>"
    + role("Technical Lead", "Gulf CRM Partners", "Jan 2023 - Present",
           ["Leads 6 developers on Sales Cloud and CPQ projects."])
    + role("Salesforce Developer", "Desert Digital", "Sep 2020 - Dec 2022",
           ["Apex and Visualforce development; Flow automation."])
    + "<h2>Education</h2><p>BEng Computer Engineering, American University of Sharjah, 2014</p>"
    "<p>BEng Computer Engineering, American University of Sharjah, 2016</p>"
    "<h2>Skills</h2><p>Apex, Visualforce, CPQ, Flow, team leadership</p>"
))

# 5. Two-column PDF.
CVS["05_maya_farouk_two_column"] = ("pdf", page(
    "<table width='100%'><tr><td width='34%' style='background:#eef;padding:8px'>"
    "<h1>Maya Farouk</h1><p>Salesforce Developer</p><p>Giza, Egypt</p><p>maya.farouk@example.com</p>"
    "<p>+20 122 555 0505</p><h2>Skills</h2><p>Apex<br/>LWC<br/>SOQL<br/>Data Cloud<br/>Agentforce<br/>Python</p>"
    "<h2>Languages</h2><p>Arabic, English, German (basic)</p>"
    "<h2>Education</h2><p>MSc Data Science, German University in Cairo, 2020</p></td>"
    "<td width='66%' style='padding:8px'><h2>Experience</h2>"
    + role("Salesforce Developer", "Horus Insurance", "04/2022 - Present",
           ["Built Agentforce actions in Apex for claims triage.",
            "Built Data Cloud segments and calculated insights for 1.2M customers."])
    + role("Data Analyst", "Sphinx Analytics", "09/2020 - 03/2022",
           ["Python and SQL dashboards; churn model with 0.81 AUC."])
    + "<h2>Achievements</h2><ul><li>Winner, Salesforce Agentforce Hackathon Cairo 2025</li></ul>"
    "</td></tr></table>"
))

# 6. A plain DOCX, junior profile.
CVS["06_karim_saleh"] = ("docx", page(
    "<h1>Karim Saleh</h1>"
    "<p>Junior Salesforce Developer | Mansoura, Egypt | karim.saleh@example.com</p>"
    "<h2>Experience</h2>"
    + role("Junior Salesforce Developer", "Delta Cloud Services", "February 2024 - Present",
           ["Builds Flows and simple Apex triggers; writes test classes."])
    + role("Salesforce Intern", "Delta Cloud Services", "2023 - 2024", ["Admin tasks, reports and dashboards."])
    + "<h2>Education</h2><p>BSc Information Systems, Mansoura University, 2023</p>"
    "<h2>Certifications</h2><p>Salesforce Certified Administrator (2023)<br/>Salesforce Certified Platform Developer I (2024)</p>"
    "<h2>Skills</h2><p>Flow, Apex, SOQL, Reports, JS</p>"
))

# 7. Bilingual CV with a French section.
CVS["07_nour_mansour_bilingual"] = ("pdf", page(
    "<h1>Nour Mansour</h1>"
    "<p>Salesforce Consultant | Paris, France | nour.mansour@example.com | +33 6 55 50 70 70</p>"
    "<h2>Experience</h2>"
    + role("Salesforce Consultant", "Lumiere Conseil", "2022-09 - Present",
           ["Service Cloud and Experience Cloud design; Apex and LWC for case portals."])
    + "<h2>Expérience précédente</h2>"
    + role("Développeuse Salesforce", "Banque du Nord", "2019-10 - 2022-08",
           ["Développement Apex et Lightning Web Components pour le CRM bancaire.",
            "Migration de données avec Data Loader."])
    + "<h2>Formation</h2><p>Master Informatique, Université Paris-Saclay, 2019</p>"
    "<h2>Skills</h2><p>Apex, LWC, Service Cloud, Experience Cloud, Data Loader</p>"
    "<h2>Languages</h2><p>French (native), English (fluent), Arabic (intermediate)</p>"
))

# 8. Scanned PDF (rasterised image, no text layer).
CVS["08_hassan_ali_scanned"] = ("scan", page(
    "<h1>Hassan Ali</h1>"
    "<p>Salesforce Developer | Riyadh, Saudi Arabia | hassan.ali@example.com | +966 55 555 0808</p>"
    "<h2>Experience</h2>"
    + role("Salesforce Developer", "Najd Telecom", "05/2021 - Present",
           ["Apex REST services and LWC for field sales; 300 users."])
    + role("Software Engineer", "Oasis Systems", "08/2018 - 04/2021", ["Java and Oracle development."])
    + "<h2>Education</h2><p>BSc Computer Science, King Saud University, 2018</p>"
    "<h2>Skills</h2><p>Apex, LWC, SOQL, Java, Oracle</p>"
))

# 9. Legacy .doc: must be rejected with a clear reason.
CVS["09_tarek_legacy"] = ("doc", page(
    "<h1>Tarek Fawzy</h1><p>Salesforce Administrator | tarek.fawzy@example.com</p>"
    "<h2>Experience</h2><p>Administrator, Cairo Foods, 2020 - Present</p>"
))

# 10. Near-duplicate of #1 (same person, edited): flagged as a possible duplicate.
CVS["10_sara_ahmed_updated"] = ("pdf", SARA.replace("7 years", "7+ years").replace(
    "Git, CI/CD with SFDX", "Git, CI/CD with SFDX, Agentforce"))


def convert(html_path, fmt, outdir):
    target = {"pdf": "pdf", "docx": "docx:MS Word 2007 XML", "doc": "doc:MS Word 97"}[fmt]
    subprocess.run(["soffice", "--headless", "--convert-to", target, "--outdir", outdir, html_path],
                   check=True, capture_output=True)


def main():
    os.makedirs(OUT, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for name, (fmt, html) in CVS.items():
            src = os.path.join(tmp, name + ".html")
            with open(src, "w", encoding="utf-8") as f:
                f.write(html)
            if fmt == "scan":
                convert(src, "pdf", tmp)
                png = os.path.join(tmp, name + ".png")
                subprocess.run(["sips", "-s", "format", "png", "-s", "dpiWidth", "110", "-s", "dpiHeight", "110",
                                os.path.join(tmp, name + ".pdf"), "--out", png], check=True, capture_output=True)
                subprocess.run(["sips", "-s", "format", "pdf", png, "--out", os.path.join(OUT, name + ".pdf")],
                               check=True, capture_output=True)
            else:
                convert(src, fmt, tmp)
                shutil.copy(os.path.join(tmp, f"{name}.{fmt}"), os.path.join(OUT, f"{name}.{fmt}"))
            print("built", name)


if __name__ == "__main__":
    main()
