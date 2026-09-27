import uuid
from datetime import datetime, timedelta, timezone
from typing import Optional, Literal
from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession
from app.db import get_db
from app.deps import get_current_user, require_role

router=APIRouter(tags=["Assessments"])
class OptionIn(BaseModel): text: str; is_correct: bool=False
class QuestionIn(BaseModel): skill_id:int; text:str; explanation:Optional[str]=None; difficulty:int=Field(2,ge=1,le=5); options:list[OptionIn]=[]
class AssessmentIn(BaseModel): title:str; instructions:Optional[str]=None; course_id:Optional[uuid.UUID]=None; skill_id:Optional[int]=None; opens_at:Optional[datetime]=None; deadline_at:Optional[datetime]=None; duration_minutes:Optional[int]=Field(None,gt=0); pass_pct:int=Field(60,ge=0,le=100); max_attempts:int=Field(1,gt=0); shuffle_questions:bool=True; lockdown_enabled:bool=True
class AnswerIn(BaseModel): selected_option_ids:list[uuid.UUID]=[]; text_answer:Optional[str]=None; rating_value:Optional[int]=None

async def owned(db, table, ident, user):
    row=(await db.execute(text(f"SELECT created_by FROM {table} WHERE id=:id"), {"id":ident})).mappings().first()
    if not row: raise HTTPException(404,"Not found")
    if user["role"] != "admin" and row["created_by"] != user["id"]: raise HTTPException(403,"Forbidden: you do not own this resource")
    return row

@router.post("/questions", status_code=201)
async def create_question(data:QuestionIn,current_user:dict=Depends(require_role("trainer","admin")),db:AsyncSession=Depends(get_db)):
    if len(data.options)!=4 or sum(o.is_correct for o in data.options)!=1: raise HTTPException(422,"MCQ questions require exactly four options and one correct answer")
    qid=uuid.uuid4(); await db.execute(text("INSERT INTO questions(id,skill_id,text,explanation,difficulty,status,created_by) VALUES(:id,:skill,:text,:explanation,:difficulty,'draft',:user)"),{"id":qid,"skill":data.skill_id,"text":data.text,"explanation":data.explanation,"difficulty":data.difficulty,"user":current_user["id"]})
    for pos,opt in enumerate(data.options,1): await db.execute(text("INSERT INTO question_options(id,question_id,text,is_correct,position) VALUES(:id,:qid,:text,:correct,:pos)"),{"id":uuid.uuid4(),"qid":qid,"text":opt.text,"correct":opt.is_correct,"pos":pos})
    await db.commit(); return {"id":qid,"status":"draft"}
@router.patch("/questions/{question_id}")
async def update_question(question_id:uuid.UUID,data:QuestionIn,current_user:dict=Depends(require_role("trainer","admin")),db:AsyncSession=Depends(get_db)):
    await owned(db,"questions",question_id,current_user)
    await db.execute(text("UPDATE questions SET skill_id=:skill,text=:text,explanation=:explanation,difficulty=:difficulty WHERE id=:id"),{"id":question_id,"skill":data.skill_id,"text":data.text,"explanation":data.explanation,"difficulty":data.difficulty}); await db.commit(); return {"id":question_id}
@router.post("/questions/{question_id}/approve")
async def approve_question(question_id:uuid.UUID,current_user:dict=Depends(require_role("trainer","admin")),db:AsyncSession=Depends(get_db)):
    await owned(db,"questions",question_id,current_user); await db.execute(text("UPDATE questions SET status='approved',reviewed_by=:user WHERE id=:id"),{"id":question_id,"user":current_user["id"]}); await db.commit(); return {"id":question_id,"status":"approved"}
@router.post("/assessments",status_code=201)
async def create_assessment(data:AssessmentIn,current_user:dict=Depends(require_role("trainer","admin")),db:AsyncSession=Depends(get_db)):
    aid=uuid.uuid4(); await db.execute(text("""INSERT INTO assessments(id,title,instructions,course_id,skill_id,created_by,opens_at,deadline_at,duration_minutes,pass_pct,max_attempts,shuffle_questions,lockdown_enabled) VALUES(:id,:title,:instructions,:course,:skill,:user,:opens,:deadline,:duration,:pass,:max,:shuffle,:lockdown)"""),{"id":aid,"title":data.title,"instructions":data.instructions,"course":data.course_id,"skill":data.skill_id,"user":current_user["id"],"opens":data.opens_at,"deadline":data.deadline_at,"duration":data.duration_minutes,"pass":data.pass_pct,"max":data.max_attempts,"shuffle":data.shuffle_questions,"lockdown":data.lockdown_enabled}); await db.commit(); return {"id":aid,"status":"draft"}
@router.post("/assessments/{assessment_id}/questions")
async def add_question(assessment_id:uuid.UUID,question_id:uuid.UUID,position:int=1,marks:float=1,current_user:dict=Depends(require_role("trainer","admin")),db:AsyncSession=Depends(get_db)):
    await owned(db,"assessments",assessment_id,current_user); q=(await db.execute(text("SELECT status FROM questions WHERE id=:id"),{"id":question_id})).mappings().first()
    if not q or q["status"]!="approved": raise HTTPException(422,"Only approved questions can be added")
    await db.execute(text("INSERT INTO assessment_questions(assessment_id,question_id,position,marks) VALUES(:a,:q,:p,:m) ON CONFLICT(assessment_id,question_id) DO UPDATE SET position=:p,marks=:m"),{"a":assessment_id,"q":question_id,"p":position,"m":marks});await db.commit();return {"ok":True}
@router.post("/assessments/{assessment_id}/open")
async def open_assessment(assessment_id:uuid.UUID,current_user:dict=Depends(require_role("trainer","admin")),db:AsyncSession=Depends(get_db)):
    await owned(db,"assessments",assessment_id,current_user);await db.execute(text("UPDATE assessments SET status='open' WHERE id=:id"),{"id":assessment_id});await db.commit();return {"id":assessment_id,"status":"open"}

async def auto_submit(db, attempt_id):
    attempt=(await db.execute(text("SELECT assessment_id FROM attempts WHERE id=:id"),{"id":attempt_id})).mappings().first(); await grade(db,attempt_id,attempt["assessment_id"],"auto_submitted")
async def grade(db,attempt_id,assessment_id,final_status="submitted"):
    rows=await db.execute(text("""SELECT aq.question_id,aq.marks,qo.id correct_id FROM assessment_questions aq JOIN question_options qo ON qo.question_id=aq.question_id AND qo.is_correct WHERE aq.assessment_id=:aid"""),{"aid":assessment_id})
    total=0;score=0
    for r in rows.mappings().all():
        total+=float(r["marks"]); ans=(await db.execute(text("SELECT selected_option_ids FROM attempt_answers WHERE attempt_id=:a AND question_id=:q"),{"a":attempt_id,"q":r["question_id"]})).mappings().first(); correct=bool(ans and r["correct_id"] in (ans["selected_option_ids"] or [])); earned=float(r["marks"]) if correct else 0;score+=earned
        await db.execute(text("UPDATE attempt_answers SET is_correct=:correct,marks_awarded=:earned WHERE attempt_id=:a AND question_id=:q"),{"correct":correct,"earned":earned,"a":attempt_id,"q":r["question_id"]})
    assessment=(await db.execute(text("SELECT pass_pct FROM assessments WHERE id=:id"),{"id":assessment_id})).mappings().first();pct=round(100*score/total,2) if total else 0
    await db.execute(text("UPDATE attempts SET status=:status,submitted_at=now(),score=:score,max_score=:total,percentage=:pct,passed=:passed WHERE id=:id"),{"status":final_status,"score":score,"total":total,"pct":pct,"passed":pct>=assessment["pass_pct"],"id":attempt_id});await db.execute(text("INSERT INTO jobs(type,payload,dedupe_key) VALUES('competency_refresh','{}',:key) ON CONFLICT DO NOTHING"),{"key":"competency:assessment"})

@router.post("/assessments/{assessment_id}/start")
async def start_attempt(assessment_id:uuid.UUID,current_user:dict=Depends(require_role("trainee")),db:AsyncSession=Depends(get_db)):
    a=(await db.execute(text("SELECT * FROM assessments WHERE id=:id"),{"id":assessment_id})).mappings().first()
    if not a or a["status"]!="open": raise HTTPException(404,"Assessment is not open")
    now=datetime.now(timezone.utc)
    if (a["opens_at"] and a["opens_at"]>now) or (a["deadline_at"] and a["deadline_at"]<now):raise HTTPException(422,"Assessment is outside its available window")
    if a["course_id"] and not (await db.execute(text("SELECT 1 FROM enrollments WHERE course_id=:course AND user_id=:user"),{"course":a["course_id"],"user":current_user["id"]})).first():raise HTTPException(403,"Enroll in the course before starting this assessment")
    number=(await db.execute(text("SELECT count(*) FROM attempts WHERE assessment_id=:a AND user_id=:u"),{"a":assessment_id,"u":current_user["id"]})).scalar() or 0
    if number>=a["max_attempts"]:raise HTTPException(422,"Maximum attempts reached")
    aid=uuid.uuid4();expires=now+timedelta(minutes=a["duration_minutes"]) if a["duration_minutes"] else a["deadline_at"];await db.execute(text("INSERT INTO attempts(id,assessment_id,user_id,attempt_no,expires_at) VALUES(:id,:assessment,:user,:number,:expires)"),{"id":aid,"assessment":assessment_id,"user":current_user["id"],"number":number+1,"expires":expires})
    qs=await db.execute(text("""SELECT q.id,q.text,q.type,q.difficulty,aq.position,aq.marks, json_agg(json_build_object('id',o.id,'text',o.text,'position',o.position) ORDER BY o.position) options FROM assessment_questions aq JOIN questions q ON q.id=aq.question_id JOIN question_options o ON o.question_id=q.id WHERE aq.assessment_id=:id GROUP BY q.id,aq.position,aq.marks ORDER BY aq.position"""),{"id":assessment_id});await db.commit();return {"attempt_id":aid,"expires_at":expires,"questions":[dict(x) for x in qs.mappings().all()]}
@router.put("/attempts/{attempt_id}/answers")
async def save_answer(attempt_id:uuid.UUID,question_id:uuid.UUID,data:AnswerIn,current_user:dict=Depends(require_role("trainee")),db:AsyncSession=Depends(get_db)):
    at=(await db.execute(text("SELECT * FROM attempts WHERE id=:id AND user_id=:user"),{"id":attempt_id,"user":current_user["id"]})).mappings().first()
    if not at:raise HTTPException(404,"Attempt not found")
    if at["expires_at"] and at["expires_at"]<datetime.now(timezone.utc):await auto_submit(db,attempt_id);await db.commit();raise HTTPException(409,"Time expired; your attempt was submitted")
    await db.execute(text("INSERT INTO attempt_answers(attempt_id,question_id,selected_option_ids,text_answer,rating_value) VALUES(:a,:q,:options,:text,:rating) ON CONFLICT(attempt_id,question_id) DO UPDATE SET selected_option_ids=:options,text_answer=:text,rating_value=:rating,answered_at=now()"),{"a":attempt_id,"q":question_id,"options":data.selected_option_ids,"text":data.text_answer,"rating":data.rating_value});await db.commit();return {"saved":True}
@router.post("/attempts/{attempt_id}/submit")
async def submit(attempt_id:uuid.UUID,current_user:dict=Depends(require_role("trainee")),db:AsyncSession=Depends(get_db)):
    at=(await db.execute(text("SELECT * FROM attempts WHERE id=:id AND user_id=:user"),{"id":attempt_id,"user":current_user["id"]})).mappings().first()
    if not at: raise HTTPException(404,"Attempt not found")
    if at["status"]!="in_progress":raise HTTPException(409,"Attempt already submitted")
    await grade(db,attempt_id,at["assessment_id"]);await db.commit();return {"attempt_id":attempt_id,"submitted":True}
@router.get("/attempts/{attempt_id}/result")
async def result(attempt_id:uuid.UUID,current_user:dict=Depends(get_current_user),db:AsyncSession=Depends(get_db)):
    at=(await db.execute(text("SELECT a.*,s.show_results FROM attempts a JOIN assessments s ON s.id=a.assessment_id WHERE a.id=:id"),{"id":attempt_id})).mappings().first()
    if not at or (current_user["role"]!="admin" and at["user_id"]!=current_user["id"]):raise HTTPException(404,"Attempt not found")
    if at["status"]=="in_progress" or not at["show_results"]:raise HTTPException(403,"Results are not available")
    answers=await db.execute(text("SELECT q.text,q.explanation,aa.is_correct,aa.marks_awarded,qo.text correct_answer FROM attempt_answers aa JOIN questions q ON q.id=aa.question_id LEFT JOIN question_options qo ON qo.question_id=q.id AND qo.is_correct WHERE aa.attempt_id=:id"),{"id":attempt_id});return {"attempt":dict(at),"answers":[dict(x) for x in answers.mappings().all()]}
